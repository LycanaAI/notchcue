#!/usr/bin/env bash
# Builds a signed, notarised and stapled NotchCue release into dist/.
#
#   make release          (or scripts/release.sh)
#
# Zips leave out extended attributes (macOS adds com.apple.provenance), which the
# signature doesn't need.
#
# Steps: build (Apple silicon + Intel) -> sign with Developer ID and the
# hardened runtime -> verify -> zip -> notarise -> staple -> zip again ->
# check with Gatekeeper -> print the sha256.
#
# Publishes nothing: the zip stays in dist/ until `make publish`.
# One-time setup and the full process: docs/releasing.md.
#
# Settings (environment variables):
#   NOTCHCUE_RELEASE_IDENTITY  signing identity (default: the first "Developer ID Application" certificate)
#   NOTCHCUE_NOTARY_PROFILE    notarytool keychain profile (default: notchcue)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="$(plutil -extract CFBundleShortVersionString raw Info.plist)"
profile="${NOTCHCUE_NOTARY_PROFILE:-notchcue}"
entitlements="$root/NotchCue.entitlements"
dist="$root/dist"
app="$dist/NotchCue.app"
zip="$dist/NotchCue-$version.zip"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

identity="${NOTCHCUE_RELEASE_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
fi
[[ -n "$identity" ]] || fail "no \"Developer ID Application\" certificate in the keychain.
Create one at https://developer.apple.com/account/resources/certificates (or in Xcode > Settings > Accounts),
or set NOTCHCUE_RELEASE_IDENTITY to the identity to use."

# Check the notary profile up front, but still build and sign so that part can be checked.
have_profile=1
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 || have_profile=0
if [[ $have_profile == 0 ]]; then
  echo "warning: notary profile \"$profile\" not found; building and signing only. See the end for how to set it up." >&2
fi

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  echo "warning: the working tree has uncommitted changes; they will be in this build." >&2
fi

step "Building NotchCue $version (arm64 + x86_64) into a clean dist/"
rm -rf "$dist"
mkdir -p "$dist"
scripts/build-app.sh --universal "$app"

step "Signing with $identity (hardened runtime, secure timestamp)"
codesign --force --options runtime --timestamp \
  --entitlements "$entitlements" \
  --sign "$identity" "$app"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$app"
details="$(codesign -dv --verbose=2 "$app" 2>&1)"
grep -E '^(Identifier|Format|Authority|TeamIdentifier|Timestamp|Runtime Version|CodeDirectory)' <<<"$details"
grep -q 'flags=.*runtime' <<<"$details" || fail "the hardened runtime flag is missing"
grep -q 'Authority=Developer ID Application' <<<"$details" || fail "not signed with a Developer ID Application certificate"
grep -q '^Timestamp=' <<<"$details" || fail "the signature has no secure timestamp"
granted="$(codesign -d --entitlements - --xml "$app" 2>/dev/null)"
grep -q 'com.apple.security.device.audio-input' <<<"$granted" || fail "the microphone entitlement is missing"

step "Zipping for notarisation"
ditto -c -k --keepParent --norsrc --noextattr "$app" "$zip"

if [[ $have_profile == 0 ]]; then
  fail "can't notarise: no notarytool keychain profile named \"$profile\".
The app in dist/ is signed but not notarised, so Gatekeeper will still block it on other Macs.

Set up the profile once (it asks for an app-specific password from https://account.apple.com,
under Sign-In and Security > App-Specific Passwords, and keeps it in your keychain):

  xcrun notarytool store-credentials $profile --apple-id YOUR_APPLE_ID --team-id AGWT2MLGA6

Then run make release again."
fi

step "Submitting to Apple's notary service (usually a few minutes)"
submit_log="$dist/notarytool-submit.log"
if ! xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait 2>&1 | tee "$submit_log"; then
  fail "notarytool submit failed; see $submit_log"
fi
submission_id="$(awk '/^ *id:/ { print $2; exit }' "$submit_log")"
if ! grep -q 'status: Accepted' "$submit_log"; then
  [[ -n "$submission_id" ]] && xcrun notarytool log "$submission_id" --keychain-profile "$profile" || true
  fail "notarisation was not accepted (log above)"
fi

step "Stapling the notarisation ticket to the app"
xcrun stapler staple "$app"
xcrun stapler validate "$app"

step "Zipping the stapled app"
rm -f "$zip"
ditto -c -k --keepParent --norsrc --noextattr "$app" "$zip"

step "Checking with Gatekeeper"
spctl -a -vvv -t exec "$app"

sha="$(shasum -a 256 "$zip" | awk '{ print $1 }')"
echo "$sha  $(basename "$zip")" > "$zip.sha256"

step "Done"
echo "Zip:     $zip"
echo "sha256:  $sha"
echo
echo "Nothing has been published. When the repo is public, run: make publish"
