# Releasing NotchCue

A release is a zip of NotchCue.app that is signed with a Developer ID, notarised by Apple and stapled, so macOS opens it without warnings. It goes up on GitHub Releases, and the Homebrew cask in [LycanaAI/homebrew-tap](https://github.com/LycanaAI/homebrew-tap) points at it.

There are two steps, and they're kept apart on purpose:

| Step | What it does | Publishes anything? |
|---|---|---|
| `make release` | Builds, signs, notarises and staples `dist/NotchCue-<version>.zip` | No |
| `make publish` | Tags the version, creates the GitHub release and updates the cask | Yes |

## One-time setup

You need:

- **A "Developer ID Application" certificate** in your keychain, for team AGWT2MLGA6. Check with:

  ```sh
  security find-identity -v -p codesigning
  ```

- **A notarytool keychain profile named `notchcue`.** Notarisation means Apple scans the app and records that it's been checked. `notarytool` needs your Apple ID and an *app-specific password*: a separate password just for this tool, made at [account.apple.com](https://account.apple.com) under Sign-In and Security → App-Specific Passwords. Store them once:

  ```sh
  xcrun notarytool store-credentials notchcue --apple-id YOUR_APPLE_ID --team-id AGWT2MLGA6
  ```

  It asks for the password and keeps it in your keychain, so it never goes in a file or a script. Check the profile works with:

  ```sh
  xcrun notarytool history --keychain-profile notchcue
  ```

- **The GitHub CLI** (`gh`), signed in with push access to LycanaAI/notchcue and LycanaAI/homebrew-tap.

## 1. Prepare the version

1. Set the new version in `Info.plist`: `CFBundleShortVersionString` (e.g. `0.2.2`), and add 1 to `CFBundleVersion`.
2. Add a `## 0.2.2` section to `CHANGELOG.md`. `make publish` uses it as the release notes.
3. Commit, and push to `main`.

## 2. `make release`

```sh
make release
```

This runs `scripts/release.sh`, which:

1. Builds NotchCue.app for Apple silicon and Intel into a clean `dist/`, targeting the macOS version in `Info.plist` (`LSMinimumSystemVersion`).
2. Signs it with the Developer ID certificate, the hardened runtime (`--options runtime`), a secure timestamp and `NotchCue.entitlements`. The hardened runtime is required for notarisation. It blocks the microphone unless the app has the `com.apple.security.device.audio-input` entitlement, which is the only one NotchCue has.
3. Verifies the signature, the hardened runtime and the entitlement.
4. Zips the app into `dist/NotchCue-<version>.zip`.
5. Submits the zip to Apple with `notarytool` and waits (usually a few minutes). If Apple rejects it, the script prints Apple's log.
6. Staples the notarisation ticket to the app, so it opens without a network check.
7. Zips the stapled app again. This is the zip to publish.
8. Checks it with Gatekeeper (`spctl -a -vvv -t exec`), which should say `accepted` and `source=Notarized Developer ID`.
9. Prints the zip's sha256 and writes it to `dist/NotchCue-<version>.zip.sha256`.

If the `notchcue` profile is missing, the script still builds, signs and verifies, then stops with the setup instructions.

Before publishing, try the app from `dist/`:

```sh
open dist/NotchCue.app
dist/NotchCue.app/Contents/Resources/notchcue --sample
```

Settings:

| Variable | Default |
|---|---|
| `NOTCHCUE_RELEASE_IDENTITY` | The first "Developer ID Application" certificate |
| `NOTCHCUE_NOTARY_PROFILE` | `notchcue` |

## 3. `make publish`

Only once LycanaAI/notchcue is public: Homebrew and the download link can't reach files in a private repo.

Check first, without changing anything:

```sh
scripts/publish.sh --dry-run
```

Then:

```sh
make publish
```

This runs `scripts/publish.sh`. It checks that:

- the zip in `dist/` matches the version in `Info.plist` and is notarised and stapled
- the repo is public
- the working tree is clean, you're on `main`, and `main` matches `origin/main`
- the tag and the GitHub release don't exist yet
- `CHANGELOG.md` has a section for the version

It shows what it's about to do and asks you to type the version to confirm. Then it:

1. Tags the commit `v<version>` and pushes the tag.
2. Creates the GitHub release with `gh release create`, attaching the zip, with that version's CHANGELOG section (plus the sha256) as the notes.
3. Downloads the zip back from the release and checks its sha256 matches.
4. Updates the tap (see below), commits and pushes it.

Settings:

| Variable | Default |
|---|---|
| `NOTCHCUE_REPO` | `LycanaAI/notchcue` |
| `NOTCHCUE_TAP_REPO` | `LycanaAI/homebrew-tap` |
| `NOTCHCUE_TAP_DIR` | A fresh temporary clone of the tap |

## How the tap gets updated

The cask is `Casks/notchcue.rb` in LycanaAI/homebrew-tap. Its download URL is built from the version:

```ruby
url "https://github.com/LycanaAI/notchcue/releases/download/v#{version}/NotchCue-#{version}.zip"
```

so a new release only changes two lines: `version` and `sha256`. `make publish` edits them, checks the file is valid Ruby, and commits `notchcue <version>` to the tap. People then get it with `brew upgrade --cask notchcue`.

To do it by hand instead: edit those two lines (the sha256 is in `dist/NotchCue-<version>.zip.sha256`), then commit and push the tap.

## Going public for the first time

1. Make LycanaAI/notchcue public (GitHub → Settings → Danger Zone → Change visibility, or `gh repo edit LycanaAI/notchcue --visibility public --accept-visibility-change-consequences`).
2. Make LycanaAI/homebrew-tap public the same way.
3. `make release` (if the zip in `dist/` isn't current), then `make publish`.
4. On a Mac without a source checkout: `brew install --cask lycanaai/tap/notchcue`, open NotchCue, and run `notchcue --sample`.
5. Remove "coming soon" from the Homebrew section of the README and the CHANGELOG.

## CI

GitHub Actions runs `make check` (compile and the built-in tests) on pull requests and pushes to `main`. It does no signing: certificates and notarisation credentials stay on the release Mac.
