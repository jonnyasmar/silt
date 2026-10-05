#!/usr/bin/env bash
# Builds Silt.app (release), signs it, and optionally installs it.
#   scripts/build-app.sh            -> build/Silt.app
#   scripts/build-app.sh --install  -> also copies to /Applications and launches
# SILT_RELEASE=1 is scripts/release.sh's mode: a universal (arm64 + x86_64)
# binary in build/release/Silt.app, signed for distribution with
# SILT_SIGN_IDENTITY (required; no ad-hoc fallback), Resources/Silt.entitlements
# and a secure timestamp.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Silt.app
IDENTITY="${SILT_SIGN_IDENTITY:-Apple Development: JONATHAN MARK ASMAR (25S9R3WA8Q)}"
RELEASE="${SILT_RELEASE:-}"

if [[ -n "$RELEASE" ]]; then
  if [[ -z "${SILT_SIGN_IDENTITY:-}" ]]; then
    echo "SILT_RELEASE needs SILT_SIGN_IDENTITY (run scripts/release.sh)" >&2
    exit 1
  fi
  APP=build/release/Silt.app
  # Multiple --arch flags build through xcbuild into a different directory.
  swift build -c release --product Silt --arch arm64 --arch x86_64
  BIN="$(swift build -c release --product Silt --arch arm64 --arch x86_64 --show-bin-path)/Silt"
else
  swift build -c release --product Silt
  BIN=.build/release/Silt
fi

if [[ ! -f Resources/AppIcon.icns || ! -d Resources/AppIcon.icon ]]; then
  swift scripts/make-icon.swift "$PWD" >/dev/null
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Silt"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# macOS 26 draws the icon (light and dark) from Assets.car, found through
# CFBundleIconName; macOS 15 uses the .icns. actool's own flattened .icns is
# discarded.
ICON_OUT="$(mktemp -d "${TMPDIR:-/tmp}/silt-actool.XXXXXX")"
trap 'rm -rf "$ICON_OUT"' EXIT
if ! xcrun actool Resources/AppIcon.icon --compile "$ICON_OUT" \
  --output-format human-readable-text --errors --warnings \
  --output-partial-info-plist "$ICON_OUT/partial.plist" \
  --app-icon AppIcon --include-all-app-icons \
  --enable-on-demand-resources NO --development-region en \
  --target-device mac --platform macosx --minimum-deployment-target 15.0 \
  >"$ICON_OUT/actool.log" || [[ ! -f "$ICON_OUT/Assets.car" ]]; then
  cat "$ICON_OUT/actool.log" >&2
  echo "actool could not compile Resources/AppIcon.icon" >&2
  exit 1
fi
cp "$ICON_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"

# Hardened runtime denies Apple Events (Finder's empty-trash) without the
# entitlement; --timestamp is required for notarization.
if [[ -n "$RELEASE" ]]; then
  codesign --force --options runtime --timestamp \
    --entitlements Resources/Silt.entitlements --sign "$IDENTITY" "$APP"
# A stable signing identity keeps the Full Disk Access grant across rebuilds.
elif security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --options runtime --entitlements Resources/Silt.entitlements \
    --sign "$IDENTITY" "$APP" >/dev/null
else
  codesign --force --sign - "$APP" >/dev/null
fi
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Silt >/dev/null 2>&1 || true
  rm -rf /Applications/Silt.app
  cp -R "$APP" /Applications/Silt.app
  open /Applications/Silt.app
  echo "installed /Applications/Silt.app"
fi
