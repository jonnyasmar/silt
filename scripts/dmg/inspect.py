#!/usr/bin/env python3
"""Fail unless a mounted Silt disk image has the designed window.

    inspect.py MOUNT_POINT layout.json

Runs in the dmgbuild venv, which is where ds_store lives. Reads the volume's
.DS_Store back and compares it with layout.json, so an image whose window
silently fell back to Finder's defaults fails instead of shipping.
"""
from __future__ import annotations

import json
import os
import sys

from ds_store import DSStore

APP = "Silt.app"


def fail(message: str) -> None:
    raise SystemExit(f"disk image check failed: {message}")


def main() -> None:
    mount, layout_path = sys.argv[1:3]
    with open(layout_path, encoding="utf-8") as source:
        layout = json.load(source)

    for name in (".DS_Store", ".VolumeIcon.icns", ".background.tiff", APP, "Applications"):
        if not os.path.lexists(os.path.join(mount, name)):
            fail(f"the volume has no {name}")
    if os.readlink(os.path.join(mount, "Applications")) != "/Applications":
        fail("Applications is not a link to /Applications")
    for name in (".VolumeIcon.icns", ".background.tiff"):
        if os.path.getsize(os.path.join(mount, name)) == 0:
            fail(f"{name} is empty")

    with DSStore.open(os.path.join(mount, ".DS_Store"), "r") as store:
        records = {(entry.filename, entry.code): entry.value for entry in store}

    bounds = records.get((".", b"bwsp"))
    if not isinstance(bounds, dict):
        fail("the window has no saved size (no bwsp record)")
    for flag in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar", "ShowTabView"):
        if bounds.get(flag):
            fail(f"{flag} is on; the window must be chrome-free")
    numbers = bounds["WindowBounds"].replace("{", "").replace("}", "").split(",")
    width, height = float(numbers[2]), float(numbers[3])
    expected = (layout["window"]["width"], layout["window"]["height"] + layout["titleBar"])
    if (round(width), round(height)) != expected:
        fail(f"window is {width:g} x {height:g}, expected {expected[0]} x {expected[1]}")

    view = records.get((".", b"icvp"))
    if not isinstance(view, dict) or round(view.get("iconSize", 0)) != layout["iconSize"]:
        fail("the icon size is not the designed one")
    if view.get("backgroundType") != 2:
        fail("the window has no background picture")

    for name, key in ((APP, "app"), ("Applications", "applications")):
        position = records.get((name, b"Iloc"))
        if position is None:
            fail(f"{name} has no saved icon position")
        if (position[0], position[1]) != (layout[key]["x"], layout[key]["y"]):
            fail(f"{name} sits at {tuple(position[:2])}, expected "
                 f"({layout[key]['x']}, {layout[key]['y']})")

    print(
        "disk image window verified: %gx%g, no toolbar or sidebar, background picture, "
        "icon size %d, %s at (%d, %d), Applications -> /Applications at (%d, %d), "
        "volume icon present"
        % (width, height, layout["iconSize"], APP, layout["app"]["x"], layout["app"]["y"],
           layout["applications"]["x"], layout["applications"]["y"]))


if __name__ == "__main__":
    main()
