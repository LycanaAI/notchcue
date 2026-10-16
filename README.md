# NotchCue

A teleprompter for macOS that hangs down from the notch, right under your camera, and follows your voice.

Read your script out loud and NotchCue scrolls along with you. Words you've said turn grey, it waits when you pause, and if you go back and say a line again it jumps back to it. Because the text sits right below the camera, your eyes stay close to the lens.

It only uses what's built into macOS: Apple's speech recognition runs on your Mac, so it works offline and nothing is sent anywhere by NotchCue. No accounts, no subscription.

## Install

Needs macOS 13 or later and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/LycanaAI/notchcue.git
cd notchcue
make install          # links `notchcue` into ~/.local/bin
```

Make sure `~/.local/bin` is on your `PATH`, or use `make install PREFIX=/usr/local`.

The first time it listens, macOS asks for **Speech Recognition** and **Microphone** access. **Dictation must also be on**: System Settings → Keyboard → Dictation. Without it, Apple's speech recognition won't run and NotchCue tells you so.

## Use

```sh
notchcue script.txt                       # follow your voice
notchcue script.txt --steady --wpm 160    # steady scroll instead
notchcue --text "Some text to read"       # text straight from the command line
pbpaste | notchcue -                      # text from a pipe
notchcue --help                           # all options
```

The command returns straight away and leaves the window open, so scripts and AI agents can launch it. Add `--wait` to block until it's closed.

Scripts are plain text. Each line is a paragraph. Lines in square brackets, like `[Intro]`, show as small grey cues and aren't read out.

### Keys

| Key | Action |
|---|---|
| V | Switch between following your voice and a steady scroll |
| Space | Pause / resume |
| ↑ / ↓ | Steady scroll: faster / slower. Voice: move your place back / forward a word |
| + / − | Bigger / smaller text |
| R | Back to the top |
| Esc or Q | Close |

Drag the window to move it.

### Options

| Option | Default | |
|---|---|---|
| `--steady` | off | Scroll at a steady pace instead of following your voice |
| `--wpm N` | 150 | Pace for `--steady` |
| `--locale ID` | system | Speech language, e.g. `en-AU`, `en-GB` |
| `--font-size N` | 40 | Text size in points |
| `--width N` / `--height N` | 760 / 280 | Window size; the height is measured below the notch |
| `--countdown N` | 3 | Seconds before a steady scroll starts |
| `--debug` | off | Log what it hears to `~/Library/Logs/notchcue.log` |

## How it works

- **Placement:** the window is borderless and sits at the top centre of the screen with a black strip behind the notch, so it looks like it drops out of the notch. On screens without a notch it sits under the menu bar.
- **Following your voice:** `SFSpeechRecognizer` streams partial transcripts from the microphone. NotchCue compares the last few words heard with the script around your current place, allowing for misheard and skipped words, and moves forward to the best match. It only jumps backwards on a strong match, so a common word like "the" can't send it back.
- **Why an app bundle:** macOS only lets apps with a reason in their `Info.plist` ask for the microphone and speech recognition, so the `notchcue` script builds a small `.app` and opens it.

## Known quirks

- Rebuilding the app gives it a new signature, so macOS asks for permissions again after you change the source.
- Speech recognition can mishear names and jargon. NotchCue passes the script's words to the recogniser as hints, and the matching tolerates the odd wrong word. If it loses you, press ↓ / ↑ to nudge it.

## Licence

MIT
