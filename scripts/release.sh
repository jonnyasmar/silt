#!/usr/bin/env bash
# Builds the distributable Silt disk image: universal, Developer ID signed,
# hardened runtime, notarized and stapled. Nothing is published.
#   scripts/release.sh  -> build/Silt-<CFBundleShortVersionString>.dmg
#
# Environment:
#   SILT_RELEASE_IDENTITY  Developer ID Application identity, by name or SHA-1.
#                          Defaults to Jonny's. A name that matches several
#                          keychain identities resolves to the first one
#                          `security find-identity` lists, by hash, because
#                          codesign refuses an ambiguous name.
#   NOTARY_PROFILE         notarytool keychain profile, or
#   NOTARY_APPLE_ID        an Apple ID, with
#   NOTARY_PASSWORD        an app-specific password for it (the release
#                          workflow's route; the team is the identity's), or
#   NOTARY_KEY_P8          App Store Connect API key file, with
#   NOTARY_KEY_ID          its key id and
#   NOTARY_ISSUER_ID       its issuer id.
# Without notary credentials the image is still built and Developer ID signed,
# but it is not notarized, and the run ends by saying so.
set -euo pipefail
cd "$(dirname "$0")/.."

WANT="${SILT_RELEASE_IDENTITY:-Developer ID Application: JONATHAN MARK ASMAR (Z4PL6853AL)}"
APP=build/release/Silt.app
PROFILE_HINT=silt-notary

# Three attempts with a growing pause, only for steps that fail transiently:
# `stapler staple` straight after `Accepted` (the ticket hasn't propagated
# yet) and hdiutil losing a race with a volume it just detached ("resource
# busy"). Never used around a signature, notarization or Gatekeeper check.
retry() {
  local attempt=1 pause=10
  until "$@"; do
    if (( attempt >= 3 )); then
      echo "giving up on: $* (after $attempt attempts)" >&2
      return 1
    fi
    echo "attempt $attempt of: $* failed; retrying in ${pause}s" >&2
    sleep "$pause"
    attempt=$((attempt + 1))
    pause=$((pause * 3))
  done
}

# Signing identity, matched at runtime.
MATCHES="$(security find-identity -v -p codesigning \
  | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(.*\)"$/\1|\2/p' \
  | awk -F'|' -v want="$WANT" 'toupper($1) == toupper(want) || $2 == want')"
if [[ -z "$MATCHES" ]]; then
  echo "no valid codesigning identity matches '$WANT'" >&2
  exit 1
fi
HASH="$(head -n1 <<<"$MATCHES" | cut -d'|' -f1)"
NAME="$(head -n1 <<<"$MATCHES" | cut -d'|' -f2-)"
if [[ "$NAME" != "Developer ID Application: "* ]]; then
  echo "'$NAME' is not a Developer ID Application identity" >&2
  exit 1
fi
TEAM_ID="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$NAME")"
echo "signing as $NAME [$HASH] ($(wc -l <<<"$MATCHES" | tr -d ' ') matching identities)"

NOTARIZING=false
NOTARY=()
if [[ -n "${NOTARY_KEY_P8:-}" ]]; then
  if [[ -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" ]]; then
    echo "NOTARY_KEY_P8 needs NOTARY_KEY_ID and NOTARY_ISSUER_ID" >&2
    exit 1
  fi
  NOTARIZING=true
  NOTARY=(--key "$NOTARY_KEY_P8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
  if [[ -z "${NOTARY_PASSWORD:-}" || -z "$TEAM_ID" ]]; then
    echo "NOTARY_APPLE_ID needs NOTARY_PASSWORD, and an identity whose name ends in its team id" >&2
    exit 1
  fi
  NOTARIZING=true
  NOTARY=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$TEAM_ID")
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARIZING=true
  NOTARY=(--keychain-profile "$NOTARY_PROFILE")
fi

# swift build compiles the working tree: a notarized build is only cut from
# committed code, so what ships is something a commit can reproduce.
if [[ -n "$(git status --porcelain)" ]]; then
  if [[ "$NOTARIZING" == true ]]; then
    echo "the working tree has uncommitted changes; commit or stash them before a notarized release" >&2
    exit 1
  fi
  echo "warning: building from a working tree with uncommitted changes" >&2
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "CFBundleShortVersionString '$VERSION' is not x.y.z" >&2
  exit 1
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Resources/Info.plist)"
DMG="build/Silt-$VERSION.dmg"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/silt-release.XXXXXX")"
trap 'rm -rf "${WORK:?}"' EXIT

# Anything but `Accepted` stops the run, including a submission still
# processing when the wait expires, so an unstapled artifact never comes out.
# Sixty minutes because a new team's first submissions have sat "In Progress"
# for longer than twenty (Spake, 2026-09-19). The receipt is kept in build/.
notarize() {
  local target="$1" receipt="$2" status id
  xcrun notarytool submit "$target" "${NOTARY[@]}" \
    --wait --timeout 60m --output-format json >"$receipt" || true
  status="$(plutil -extract status raw -o - "$receipt" 2>/dev/null || echo unknown)"
  id="$(plutil -extract id raw -o - "$receipt" 2>/dev/null || true)"
  echo "notarization of $target: $status (submission ${id:-none}, receipt $receipt)"
  if [[ "$status" != Accepted ]]; then
    cat "$receipt" >&2
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY[@]}" >&2 || true
    echo "notarization was not accepted; 'xcrun notarytool info $id' reports one still in progress" >&2
    exit 1
  fi
}

# 1. Universal app, signed for distribution.
SILT_RELEASE=1 SILT_SIGN_IDENTITY="$HASH" scripts/build-app.sh

# 2. Verify what was built before anything is sent to Apple.
BIN="$APP/Contents/MacOS/Silt"
echo "lipo -archs: $(lipo -archs "$BIN")"
lipo "$BIN" -verify_arch arm64 x86_64
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvvv "$APP" >"$WORK/details" 2>&1
grep -qxF "Authority=$NAME" "$WORK/details" || { echo "not signed by $NAME" >&2; exit 1; }
grep -q '^CodeDirectory .*flags=.*runtime' "$WORK/details" || { echo "hardened runtime is off" >&2; exit 1; }
grep -q '^Timestamp=' "$WORK/details" || { echo "no secure timestamp" >&2; exit 1; }
codesign -d --entitlements - --xml "$APP" >"$WORK/entitlements.plist" 2>/dev/null
if [[ "$(plutil -convert json -o - "$WORK/entitlements.plist")" != \
      "$(plutil -convert json -o - Resources/Silt.entitlements)" ]]; then
  echo "signed entitlements differ from Resources/Silt.entitlements" >&2
  exit 1
fi
echo "signature, hardened runtime, timestamp and entitlements verified"

# 3. Notarize and staple the app, so the copy a user drags out of the image
#    carries its own ticket and opens offline.
if [[ "$NOTARIZING" == true ]]; then
  ditto -c -k --keepParent "$APP" "$WORK/Silt.zip"
  notarize "$WORK/Silt.zip" "build/Silt-$VERSION-app-notary.json"
  retry xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  codesign --verify --deep --strict "$APP"
fi

# 4. The disk image, read back from the volume, then signed: an unsigned
#    container is what Gatekeeper quarantines.
retry scripts/build-dmg.sh build "$APP" "$DMG"
scripts/build-dmg.sh inspect "$DMG"
# Without --identifier codesign names it after the file up to the first dot.
codesign --force --sign "$HASH" --timestamp --identifier "$BUNDLE_ID.dmg" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

# 5. Notarize and staple the image.
if [[ "$NOTARIZING" == true ]]; then
  notarize "$DMG" "build/Silt-$VERSION-dmg-notary.json"
  retry xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi
retry hdiutil verify -quiet "$DMG"

# 6. Gatekeeper. `-t open --context context:primary-signature` is how it
#    assesses a disk image; `-t exec` is for the app. Without notarization
#    both are expected to reject, so they only fail the run when notarizing.
echo "spctl -a -t open --context context:primary-signature -v $DMG"
spctl -a -t open --context context:primary-signature -v "$DMG" || [[ "$NOTARIZING" == false ]]
echo "spctl -a -t exec -vv $APP"
spctl -a -t exec -vv "$APP" || [[ "$NOTARIZING" == false ]]

echo
echo "$DMG  $(stat -f%z "$DMG") bytes  sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"

if [[ "$NOTARIZING" == true ]]; then
  echo "Developer ID signed, notarized and stapled. Nothing has been published."
  exit 0
fi

cat >&2 <<TEXT

########################################################################
#  NOT NOTARIZED -- DO NOT DISTRIBUTE
#
#  $DMG is Developer ID signed but NOT notarized.
#  Gatekeeper will block it on every other Mac.
#
#  One-time setup (asks for an app-specific password from
#  account.apple.com and stores it in your keychain):
#
#    xcrun notarytool store-credentials $PROFILE_HINT \\
#      --apple-id <your Apple ID email> --team-id $TEAM_ID
#
#  Then: NOTARY_PROFILE=$PROFILE_HINT scripts/release.sh
########################################################################
TEXT
