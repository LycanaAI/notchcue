# NotchCue

A teleprompter for macOS that hangs down from the notch, right under your camera, and follows your voice.

<p align="center"><img src="docs/demo.gif" width="760" alt="NotchCue following a voice: words turn grey as they're read and the panel scrolls along"></p>

## What it is

Read your script out loud and NotchCue scrolls along with you. Because the text sits right below the camera, your eyes stay close to the lens.

- **Follows your voice.** Words you've said turn grey, it waits when you pause, and if you go back and say a line again it jumps back to it. Prefer a fixed pace? Switch to a steady scroll.
- **Sits around the notch.** The panel drops from the top of the screen with the notch inside it, and shrinks to a small pill when you don't need it.
- **Opens your scripts as they are.** Plain text, Markdown, Word, RTF, HTML and PDF. Drag a file onto the panel, press ⌘O, or paste with ⌘V.
- **Private and free.** It uses Apple's speech recognition on your Mac, so it works offline and NotchCue sends nothing anywhere. No accounts, no subscription.
- **Scriptable.** A `notchcue` command opens a script and returns straight away, so your own scripts and AI agents can launch it.

## Install

Needs macOS 13 (Ventura) or later, on Apple silicon or Intel.

### Homebrew (recommended)

```sh
brew install --cask lycanaai/tap/notchcue
```

This installs NotchCue.app into `/Applications` and the `notchcue` command into Homebrew's `bin`. `brew upgrade --cask notchcue` updates both.

### Download

Download `NotchCue-<version>.zip` from [Releases](https://github.com/LycanaAI/notchcue/releases), unzip it and drag NotchCue.app into Applications. For the command line, link the launcher inside the app onto your `PATH`:

```sh
ln -s /Applications/NotchCue.app/Contents/Resources/notchcue /usr/local/bin/notchcue
```

Releases are signed with a Developer ID and notarised by Apple, so macOS opens them without warnings, and the permissions you grant carry over when you update.

### Build from source

See [Contributing](#contributing).

### First run

The first time it listens, macOS asks for **Speech Recognition** and **Microphone** access. Allow both.

**Dictation must also be on**: System Settings → Keyboard → Dictation. Without it, Apple's speech recognition won't run, and NotchCue tells you so.

## How to use

### Open a script

- **From Spotlight:** press ⌘Space, type "NotchCue". With no script, the panel offers to open a file or try a sample.
- **Drag and drop** a file onto the panel, or onto NotchCue.app in Finder or the Dock. Selected text works too.
- **⌘O** or **Open Script…** in the menu bar. **Open Recent** lists your last 5 scripts.
- **⌘V** pastes the text on the clipboard as the script.
- **From the command line:**

  ```sh
  notchcue script.txt                       # follow your voice
  notchcue notes.md                         # Markdown, Word, RTF, HTML and PDF work too
  notchcue script.txt --steady --wpm 160    # steady scroll instead
  notchcue --text "Some text to read"       # text straight from the command line
  pbpaste | notchcue -                      # text from a pipe
  notchcue --help                           # all options
  ```

  The command returns straight away and leaves the window open. Add `--wait` to block until it's closed. Running it again replaces the NotchCue that's open.

Then just start reading out loud.

### Writing scripts

| Format | How it's read |
|---|---|
| `.txt` | Each line is a paragraph. Lines in `[square brackets]` are grey cues that aren't read out. |
| `.md`, `.markdown` | Headings become cues. Bold, italic, code and link markup are stripped. Images, code blocks, HTML comments and front matter are left out. |
| `.docx`, `.doc`, `.rtf`, `.rtfd`, `.odt`, `.html`, `.htm`, `.webarchive` | The text only, through macOS's document reader. |
| `.pdf` | The text, with lines joined back into paragraphs. Scanned PDFs have no text to read. |

[docs/script-format.md](docs/script-format.md) has the full rules and an example.

### Keys

Click the panel first so it has the keyboard.

| Key | Action |
|---|---|
| Space | Pause / resume |
| V | Switch between following your voice and a steady scroll. If listening stopped, V tries again. |
| ↑ / ↓ | Steady scroll: faster / slower. Voice: move your place back / forward a word |
| + / − | Bigger / smaller text |
| R | Back to the top |
| M | Minimise / expand |
| ? | Help |
| ⌘O / ⌘V | Open / paste a script |
| ⌘, | Settings |
| Esc or Q | Close NotchCue (Esc closes the help first if it's open) |

### The panel

- **Hover controls:** move the mouse over the panel and a row of buttons fades in: pause, voice/steady, text size, minimise, settings, help and close. They fade out again while you read.
- **Minimise:** press **M** or click **⌃**. The panel shrinks to a pill under the notch with a status dot (green listening, orange paused, blue scrolling, grey not listening), the rest of your current line, and how far through you are. Click it or press **M** to expand. Voice following keeps your place while minimised.
- **Help:** press **?** for a cheat sheet over the text.
- **Move it:** drag the panel anywhere.

### The menu bar

NotchCue has no Dock icon. While it's running, its icon (three centred lines) in the menu bar has everything: open and recent scripts, pause, voice or steady scroll, back to top, text size, speed, show/hide, minimise, settings, help and quit.

### Settings

Open with ⌘, or **Settings…** in the menu. Changes apply straight away and are kept for next time. Command-line options override them for one run.

| Setting | Default | Command-line option |
|---|---|---|
| Text size | 40 pt | `--font-size N` |
| Panel width | 760 pt | `--width N` |
| Panel height (below the notch) | 280 pt | `--height N` |
| Speech language | Your system language | `--locale ID` (e.g. `en-AU`) |
| Start in | Follow voice | `--steady` or `--voice` |
| Steady speed | 150 words a minute | `--wpm N` |
| Countdown before a steady scroll | 3 seconds | `--countdown N` (0 = none) |

Other options: `--sample` shows a sample script, `--debug` logs what it hears to `~/Library/Logs/notchcue.log`, `--validate` checks the options and file without opening anything.

### Troubleshooting

- **"Turn on Dictation first":** turn it on in System Settings → Keyboard → Dictation, then press V.
- **It doesn't react to my voice:** check NotchCue is allowed under System Settings → Privacy & Security → **Microphone** and **Speech Recognition**, and that the speech language in Settings matches the language you're reading.
- **The microphone is in use by another app:** a video call can take the microphone. Close or mute it, then press V to start listening again. Recording apps like QuickTime or OBS usually work alongside it.
- **"Speech recognition stopped":** press V to retry. If it keeps happening, run with `--debug` and look at `~/Library/Logs/notchcue.log`.
- **It loses my place:** speech recognition can mishear names and jargon. Press ↓ / ↑ to nudge it.
- **I can't find the menu bar icon:** on a crowded menu bar, macOS hides icons that don't fit beside the notch. Minimise the panel (M) to uncover more of the menu bar, or use the hover controls and keys.
- **The panel is gone:** choose **Show Panel** in the menu bar, or open NotchCue again from Spotlight.

## Contributing

Bug reports, ideas and pull requests are welcome. [Open an issue](https://github.com/LycanaAI/notchcue/issues) first for anything big, so we can agree on the approach.

### Build from source

Needs the Xcode command line tools (`xcode-select --install`). There are no other dependencies.

```sh
git clone https://github.com/LycanaAI/notchcue.git
cd notchcue
make install      # app into ~/Applications, `notchcue` into ~/.local/bin
./notchcue --sample
```

`make install PREFIX=/usr/local` puts the command somewhere else, and `make uninstall` removes both.

Local builds are signed with your Apple Development certificate if you have one, so macOS remembers the permissions across rebuilds. Without one they're signed ad-hoc, and macOS asks for permission again after each rebuild. `NOTCHCUE_SIGN_IDENTITY` picks a certificate by name or SHA-1, or `-` for ad-hoc.

### Before you open a pull request

- Run `make check`. It compiles NotchCue and runs the built-in tests (Markdown parsing, file loading, the voice matcher). CI runs the same thing on every pull request.
- Add a test for parsing or matching changes, and a line to [CHANGELOG.md](CHANGELOG.md) under Unreleased.
- Keep it to built-in macOS frameworks. No third-party dependencies.

### How it works

- **Code:** `swiftc` compiles the files in `Sources/`. The `notchcue` script builds a small `.app` and opens it, because macOS only lets apps with a reason in their `Info.plist` ask for the microphone and speech recognition.
- **Following your voice:** `SFSpeechRecognizer` streams partial transcripts from the microphone. NotchCue compares the last few words heard with the script around your place, allowing for misheard and skipped words, and moves to the best match. It only jumps backwards on a strong match, so a common word like "the" can't send it back.
- **Placement:** the panel is a borderless window whose top edge is the top of the screen. It covers the middle of the menu bar with the notch inside its black top strip, and the text starts just below the notch.
- **Releases:** `make release` builds the signed, notarised zip and `make publish` tags it and updates the Homebrew cask. See [docs/releasing.md](docs/releasing.md).

## Like it?

If NotchCue helps you, please ⭐ star the repo. It helps other people find it.

## Licence

MIT

---

Built by the [Lycana](https://lycana.ai) team.
