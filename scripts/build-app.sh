#!/usr/bin/env bash
# Assembles NotchCue.app from the source, without signing it.
#
#   scripts/build-app.sh build/NotchCue.app              # this Mac's architecture (development)
#   scripts/build-app.sh --universal dist/NotchCue.app   # Apple silicon + Intel (release)
#
# The binary targets the macOS version in Info.plist (LSMinimumSystemVersion),
# not the macOS it's built on. The `notchcue` launcher goes into
# Contents/Resources so the command line works from an installed app too.
set -euo pipefail

universal=0
if [[ "${1:-}" == "--universal" ]]; then
  universal=1
  shift
fi
[[ $# == 1 ]] || { echo "usage: $0 [--universal] OUTPUT.app" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$1"
plist="$root/Info.plist"
minos="$(plutil -extract LSMinimumSystemVersion raw "$plist")"

if [[ $universal == 1 ]]; then
  archs=(arm64 x86_64)
else
  archs=("$(uname -m)")
fi

tmp="$(mktemp -d -t notchcue-build)"
trap 'rm -rf "$tmp"' EXIT

slices=()
for arch in "${archs[@]}"; do
  swiftc -O -target "$arch-apple-macos$minos" "$root"/Sources/*.swift -o "$tmp/notchcue-$arch"
  slices+=("$tmp/notchcue-$arch")
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [[ ${#slices[@]} == 1 ]]; then
  cp "${slices[0]}" "$app/Contents/MacOS/notchcue"
else
  lipo -create "${slices[@]}" -output "$app/Contents/MacOS/notchcue"
fi
cp "$plist" "$app/Contents/Info.plist"
cp "$root/notchcue" "$app/Contents/Resources/notchcue"
chmod 755 "$app/Contents/Resources/notchcue"
