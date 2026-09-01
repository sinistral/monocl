#!/usr/bin/env bash
# Rasterize Icon/monocl.svg into the app icon set.
#
# The PNGs are committed, so building MonoCl needs none of this; only
# regenerating the icon does.  Requires rsvg-convert (MacPorts:
# `port install librsvg`).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_svg="$repo_root/Icon/monocl.svg"
iconset="$repo_root/MonoCl/Assets.xcassets/AppIcon.appiconset"

if ! command -v rsvg-convert >/dev/null; then
  echo "rsvg-convert not found; install librsvg" >&2
  exit 1
fi

# Each entry is "pixels:filename".  16@2x and 32@1x are both 32 pixels
# and are separate files: the catalog addresses them by name, not size.
count=0
for entry in \
  16:icon_16x16.png       32:icon_16x16@2x.png \
  32:icon_32x32.png       64:icon_32x32@2x.png \
  128:icon_128x128.png    256:icon_128x128@2x.png \
  256:icon_256x256.png    512:icon_256x256@2x.png \
  512:icon_512x512.png    1024:icon_512x512@2x.png
do
  px="${entry%%:*}"
  name="${entry##*:}"
  rsvg-convert -w "$px" -h "$px" "$source_svg" -o "$iconset/$name"
  count=$((count + 1))
done

echo "Wrote $count PNGs to $iconset"
