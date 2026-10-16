#!/usr/bin/env bash
# Publishes the release that `make release` built into dist/:
#   1. tags the current commit vX.Y.Z and pushes the tag
#   2. creates the GitHub release with the notarised zip and the CHANGELOG notes
#   3. updates the Homebrew cask (version + sha256) in LycanaAI/homebrew-tap and pushes it
#
#   make publish                        (asks before changing anything)
#   scripts/publish.sh --dry-run        (runs the checks, changes nothing)
#   scripts/publish.sh --yes            (no question; for when you're sure)
#
# Run it only once the notchcue repo is public: Homebrew and the Releases
# download link can't reach a private repo. Full process: docs/releasing.md.
#
# Settings (environment variables):
#   NOTCHCUE_REPO      GitHub repo for the app (default: LycanaAI/notchcue)
#   NOTCHCUE_TAP_REPO  GitHub repo for the tap (default: LycanaAI/homebrew-tap)
#   NOTCHCUE_TAP_DIR   existing clone of the tap to use (default: a fresh temporary clone)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

repo="${NOTCHCUE_REPO:-LycanaAI/notchcue}"
tap_repo="${NOTCHCUE_TAP_REPO:-LycanaAI/homebrew-tap}"
dry_run=0
assume_yes=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --yes|-y) assume_yes=1 ;;
    *) echo "usage: $0 [--dry-run] [--yes]" >&2; exit 2 ;;
  esac
done

version="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
tag="v$version"
app="dist/NotchCue.app"
zip="dist/NotchCue-$version.zip"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

step "Checking NotchCue $version is ready to publish"

[[ -f "$zip" && -d "$app" ]] || fail "$zip not found. Run make release first."
[[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" == "$version" ]] \
  || fail "dist/ holds a different version from Info.plist. Run make release again."
xcrun stapler validate "$app" >/dev/null || fail "the app in dist/ isn't notarised and stapled. Run make release."
spctl -a -t exec "$app" 2>/dev/null || fail "Gatekeeper rejects the app in dist/. Run make release."
sha="$(shasum -a 256 "$zip" | awk '{ print $1 }')"
echo "zip:    $zip"
echo "sha256: $sha"

visibility="$(gh repo view "$repo" --json visibility -q .visibility)"
[[ "$visibility" == "PUBLIC" ]] || fail "$repo is $visibility. Make it public first (see docs/releasing.md);
Homebrew users can't download release files from a private repo."
tap_visibility="$(gh repo view "$tap_repo" --json visibility -q .visibility)"
[[ "$tap_visibility" == "PUBLIC" ]] || echo "warning: $tap_repo is $tap_visibility; brew install won't work for others until it's public." >&2

[[ -z "$(git status --porcelain)" ]] || fail "uncommitted changes. Commit them, then run make release and make publish again."
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "not on main."
git fetch --quiet origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main isn't the same as origin/main. Push (or pull) first."
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1; then
  fail "tag $tag already exists. Bump the version in Info.plist (and CHANGELOG.md) for a new release."
fi
gh release view "$tag" --repo "$repo" >/dev/null 2>&1 && fail "a GitHub release for $tag already exists."

# Release notes: this version's section of CHANGELOG.md.
notes="$(mktemp -t notchcue-notes)"
awk -v v="## $version" '$0 == v { on = 1; next } on && /^## / { exit } on' CHANGELOG.md > "$notes"
[[ -s "$notes" ]] || fail "CHANGELOG.md has no \"## $version\" section."
printf '\n---\n\nInstall with Homebrew: `brew install --cask lycanaai/tap/notchcue`\n\nSigned with a Developer ID and notarised by Apple.\n\nsha256: `%s`\n' "$sha" >> "$notes"

echo
echo "This will:"
echo "  - tag $(git rev-parse --short HEAD) as $tag and push the tag to $repo"
echo "  - create the GitHub release $tag with $(basename "$zip")"
echo "  - set the cask in $tap_repo to version $version, sha256 $sha, and push it"

if [[ $dry_run == 1 ]]; then
  echo
  echo "Dry run: nothing changed. Release notes would be:"
  echo
  cat "$notes"
  exit 0
fi

if [[ $assume_yes == 0 ]]; then
  read -r -p "Publish NotchCue $version? Type the version to confirm: " answer
  [[ "$answer" == "$version" ]] || fail "not confirmed; nothing changed."
fi

step "Tagging $tag"
git tag -a "$tag" -m "NotchCue $version"
git push origin "$tag"

step "Creating the GitHub release"
gh release create "$tag" "$zip" --repo "$repo" --title "NotchCue $version" --notes-file "$notes" --verify-tag

step "Checking the download matches"
url="https://github.com/$repo/releases/download/$tag/$(basename "$zip")"
downloaded="$(curl -fsSL "$url" | shasum -a 256 | awk '{ print $1 }')"
[[ "$downloaded" == "$sha" ]] || fail "the downloaded zip's sha256 ($downloaded) doesn't match $sha"

step "Updating the Homebrew cask"
if [[ -n "${NOTCHCUE_TAP_DIR:-}" ]]; then
  tap_dir="$NOTCHCUE_TAP_DIR"
  git -C "$tap_dir" pull --ff-only
else
  tap_dir="$(mktemp -d -t notchcue-tap)"
  gh repo clone "$tap_repo" "$tap_dir"
fi
cask="$tap_dir/Casks/notchcue.rb"
[[ -f "$cask" ]] || fail "$cask not found"
sed -i '' -E \
  -e "s/^  version \"[^\"]*\"/  version \"$version\"/" \
  -e "s/^  sha256 \"[^\"]*\"/  sha256 \"$sha\"/" \
  "$cask"
grep -q "version \"$version\"" "$cask" && grep -q "sha256 \"$sha\"" "$cask" || fail "couldn't update $cask"
ruby -c "$cask" >/dev/null
git -C "$tap_dir" add Casks/notchcue.rb
git -C "$tap_dir" commit -m "notchcue $version"
git -C "$tap_dir" push

step "Published NotchCue $version"
echo "Release: https://github.com/$repo/releases/tag/$tag"
echo "Install: brew install --cask lycanaai/tap/notchcue"
