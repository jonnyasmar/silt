# dmgbuild settings for Silt's disk image; scripts/build-dmg.sh is the only
# caller. dmgbuild writes the window's .DS_Store itself, so no Finder session
# or AppleScript is involved. Geometry comes from layout.json, the same file
# scripts/make-dmg-background.swift draws the arrow from, so the picture and
# the icon positions can't drift apart.
import json
import os

with open(defines["layout"], encoding="utf-8") as _source:
    _layout = json.load(_source)

application = defines["app"]
application_name = os.path.basename(application.rstrip("/"))

# ULFO is LZFSE (macOS 10.11+, well under Silt's 15.0 floor): smaller and
# faster than UDZO. HFS+ because an APFS image buys nothing here.
format = "ULFO"
filesystem = "HFS+"

files = [application]
symlinks = {"Applications": "/Applications"}

# Becomes .VolumeIcon.icns.
icon = defines["volume_icon"]

# The 1x picture; dmgbuild finds dmg-background@2x.png beside it and combines
# the pair into one HiDPI .background.tiff.
background = defines["background"]

# A fixed, chrome-free window.
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
arrange_by = None
show_icon_preview = False
show_item_info = False

# The bounds include the title bar, so the content area is exactly the size of
# the background picture.
window_rect = (
    (200, 140),
    (_layout["window"]["width"], _layout["window"]["height"] + _layout["titleBar"]),
)
icon_size = _layout["iconSize"]
text_size = _layout["textSize"]
icon_locations = {
    application_name: (_layout["app"]["x"], _layout["app"]["y"]),
    "Applications": (_layout["applications"]["x"], _layout["applications"]["y"]),
}
