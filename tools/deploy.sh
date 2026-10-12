#!/usr/bin/env bash
set -Eeuo pipefail

# Run from the repository root after compiling. The optional second argument
# selects the source directory. Keep only files used by the running server.
if (($# < 1 || $# > 2)); then
    echo "usage: $0 destination [source-directory]" >&2
    exit 64
fi
if (($# == 2)); then
    cd "$2"
fi
destination="$1"
mkdir -p "$destination"
cp fortune13.dmb fortune13.rsc "$destination/"

for directory in _maps icons/effects icons/mob/clothing icons/mob/inhands \
    icons/mob/simple icons/obj icons/runtime sound/runtime strings tgui/public; do
    if [[ -d "$directory" ]]; then
        mkdir -p "$destination/$directory"
        cp -a "$directory/." "$destination/$directory/"
    fi
done

# The normal TGUI build uses committed fonts and does not generate dist.
# The game asset loader nevertheless reads these dist paths at runtime.
mkdir -p "$destination/tgui/packages/tgfont/dist"
font_source=tgui/packages/tgfont/static
if [[ -f tgui/packages/tgfont/dist/tgfont.woff2 ]]; then
    font_source=tgui/packages/tgfont/dist
fi
for asset in tgfont.css tgfont.eot tgfont.woff2; do
    cp "$font_source/$asset" "$destination/tgui/packages/tgfont/dist/"
done

# Fail rather than deploy an image with missing UI bundles.
test -s "$destination/tgui/public/tgui.bundle.js"
test -s "$destination/tgui/public/tgui-panel.bundle.js"
test -s "$destination/tgui/public/tgui-say.bundle.js"

if [[ "$(uname -o)" == Msys ]]; then
    cp ./*.dll "$destination/"
fi
