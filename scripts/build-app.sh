#!/usr/bin/env bash
# Builds Silt.app (release), signs it, and optionally installs it.
#   scripts/build-app.sh            -> build/Silt.app
#   scripts/build-app.sh --install  -> also copies to /Applications and launches
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Silt.app
IDENTITY="${SILT_SIGN_IDENTITY:-Apple Development: JONATHAN MARK ASMAR (25S9R3WA8Q)}"

swift build -c release --product Silt

if [[ ! -f Resources/AppIcon.icns || ! -d Resources/AppIcon.icon ]]; then
  swift scripts/make-icon.swift "$PWD" >/dev/null
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Silt "$APP/Contents/MacOS/Silt"
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

# A stable signing identity keeps the Full Disk Access grant across rebuilds.
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --options runtime --sign "$IDENTITY" "$APP" >/dev/null
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
