#!/usr/bin/env bash
# Builds, or inspects, Silt's drag-to-install disk image. Nothing is signed or
# notarized here; scripts/release.sh does that to the image this writes.
#   scripts/build-dmg.sh build   path/Silt.app out.dmg
#   scripts/build-dmg.sh inspect out.dmg
#
# dmgbuild writes the window's .DS_Store itself (no Finder, no AppleScript):
# no toolbar or sidebar, Resources/dmg-background.png (+@2x), Silt.app left,
# an Applications link right, the app icon as the volume icon. Positions are in
# scripts/dmg/layout.json. `inspect` mounts an image read-only and fails unless
# it reads all of that back from the volume.
#
# dmgbuild is installed into .build/dmg-tools from scripts/dmg/requirements.txt
# (exact versions, --require-hashes).
set -euo pipefail
cd "$(dirname "$0")/.."

VENV="$PWD/.build/dmg-tools"
REQUIREMENTS=scripts/dmg/requirements.txt
LAYOUT=scripts/dmg/layout.json
BACKGROUND=Resources/dmg-background.png
VOLUME_ICON=Resources/AppIcon.icns

ensure_tool() {
  local pinned
  pinned="$(sed -n 's/^dmgbuild==\([0-9.]*\).*/\1/p' "$REQUIREMENTS")"
  if [[ -x "$VENV/bin/python3" ]] && "$VENV/bin/python3" - "$pinned" <<'PY' 2>/dev/null
import importlib.metadata, sys
sys.exit(0 if importlib.metadata.version("dmgbuild") == sys.argv[1] else 1)
PY
  then
    return
  fi
  echo "installing dmgbuild $pinned into $VENV (hash-pinned)" >&2
  python3 -m venv --clear "$VENV"
  "$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check \
    --require-hashes -r "$REQUIREMENTS"
}

case "${1:-}" in
  build)
    APP="${2:?usage: build-dmg.sh build path/Silt.app out.dmg}"
    OUT="${3:?usage: build-dmg.sh build path/Silt.app out.dmg}"
    [[ -d "$APP" ]] || { echo "$APP is not an app bundle" >&2; exit 1; }
    for f in "$BACKGROUND" "${BACKGROUND%.png}@2x.png" "$VOLUME_ICON" "$LAYOUT"; do
      [[ -f "$f" ]] || { echo "missing $f (swift scripts/make-dmg-background.swift)" >&2; exit 1; }
    done
    ensure_tool
    rm -f "$OUT"
    # dmgbuild stages a writable image as large as the app; keep it beside the
    # output and remove it however we exit.
    SCRATCH="$(mktemp -d "$(dirname "$OUT")/.silt-dmg.XXXXXX")"
    trap 'rm -rf "${SCRATCH:?}"' EXIT
    TMPDIR="$SCRATCH" "$VENV/bin/dmgbuild" -s scripts/dmg/settings.py \
      -D "app=$APP" -D "layout=$LAYOUT" \
      -D "background=$BACKGROUND" -D "volume_icon=$VOLUME_ICON" \
      Silt "$OUT"
    ;;
  inspect)
    IMAGE="${2:?usage: build-dmg.sh inspect out.dmg}"
    ensure_tool
    MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/silt-dmg-inspect.XXXXXX")"
    trap 'hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
    hdiutil attach "$IMAGE" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" -quiet
    "$VENV/bin/python3" scripts/dmg/inspect.py "$MOUNT" "$LAYOUT"
    # The copy dmgbuild made must still carry an intact signature.
    codesign --verify --deep --strict "$MOUNT/Silt.app"
    echo "signature of Silt.app on the volume verified"
    ;;
  *)
    echo "usage: build-dmg.sh build APP OUT.dmg | build-dmg.sh inspect IMAGE.dmg" >&2
    exit 2
    ;;
esac
