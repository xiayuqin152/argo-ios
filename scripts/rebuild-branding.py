#!/usr/bin/env python3
"""Derive the iOS icon from Argo's original 1024 PNG using ImageMagick 6."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
ASSETS = Path("ios/Argo/Resources/Assets.xcassets")
ICON = ASSETS / "AppIcon.appiconset/Argo.png"
MARK = ASSETS / "ArgoMark.imageset/Argo.png"
LOGO = Path("docs/branding/argo-logo.png")


def render_icon(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["convert", str(source), "-background", "#C4D9B3", "-alpha", "remove",
         "-alpha", "off", "-strip", "-depth", "8",
         "-define", "png:exclude-chunks=date,time", f"PNG24:{target}"],
        check=True,
        env={**os.environ, "MAGICK_THREAD_LIMIT": "2"},
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, default=ROOT)
    output = parser.parse_args().output_root.resolve()
    source = ROOT / LOGO
    (output / LOGO).parent.mkdir(parents=True, exist_ok=True)
    if source != output / LOGO:
        shutil.copyfile(source, output / LOGO)
    render_icon(source, output / ICON)
    (output / MARK).parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(output / ICON, output / MARK)
    print("Preserved original 1024x1024 logo; rebuilt opaque RGB AppIcon and ArgoMark")


if __name__ == "__main__":
    main()
