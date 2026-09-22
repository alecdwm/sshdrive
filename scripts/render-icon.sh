#!/bin/sh
# Rasterise Resources/icon/sshdrive.svg into every PNG the app and the docs need:
#
#   Apps/Agent/Assets.xcassets/AppIcon.appiconset/icon_<size>[@2x].png   the macOS icon set
#   docs/assets/icon-256.png                                            README and docs site
#
# The renderer is resvg (through the `resvg-py` wheel, which bundles it), driven by uv so
# nothing has to be installed first. resvg is a self-contained Rust rasteriser: unlike
# cairosvg it needs no system libcairo, and unlike a headless browser it is a few megabytes.
# The SVG uses no text elements, so no font configuration is involved.
#
# Usage: scripts/render-icon.sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
svg="$root/Resources/icon/sshdrive.svg"
iconset="$root/Apps/Agent/Assets.xcassets/AppIcon.appiconset"
docs="$root/docs/assets"

command -v uv >/dev/null 2>&1 || { echo "render-icon: uv is not on PATH" >&2; exit 1; }
[ -f "$svg" ] || { echo "render-icon: no $svg" >&2; exit 1; }

mkdir -p "$iconset" "$docs"

# name:pixels, one per line. The @2x entries are the same artwork at twice the point size.
targets="
$iconset/icon_16x16.png:16
$iconset/icon_16x16@2x.png:32
$iconset/icon_32x32.png:32
$iconset/icon_32x32@2x.png:64
$iconset/icon_128x128.png:128
$iconset/icon_128x128@2x.png:256
$iconset/icon_256x256.png:256
$iconset/icon_256x256@2x.png:512
$iconset/icon_512x512.png:512
$iconset/icon_512x512@2x.png:1024
$docs/icon-256.png:256
"

printf '%s\n' "$targets" | grep -v '^$' | SVG="$svg" uv run --quiet --with resvg-py python -c '
import os, struct, sys

import resvg_py

svg = os.environ["SVG"]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    path, size = line.rsplit(":", 1)
    size = int(size)
    png = bytes(resvg_py.svg_to_bytes(svg_path=svg, width=size, height=size))
    with open(path, "wb") as f:
        f.write(png)
    # PNG IHDR: 8-byte signature, then length + "IHDR" + width + height, big endian.
    w, h = struct.unpack(">II", png[16:24])
    if (w, h) != (size, size):
        sys.exit("render-icon: %s came out %dx%d, wanted %d" % (path, w, h, size))
    print("%5d x %-5d %s" % (w, h, path))
'
