#!/usr/bin/env bash
# Rebuilds fonts/BoardSymbols.ttf: the symbol blocks of Noto Sans Symbols,
# Noto Sans Symbols 2, Noto Sans Math and Noto Sans Mono (box drawing) merged
# into one font, so that the web board draws arrows, ticks, shapes and box
# lines without the web engine fetching Noto fonts from fonts.gstatic.com.
# The sources are the files the engine of Flutter 3.32 would fetch. Needs
# curl and fonttools with brotli (e.g. `nix shell --impure --expr
# '(import <nixpkgs> {}).python3.withPackages (p: [p.fonttools p.brotli])'`).
#
#   tool/symbols_font.sh        # run in packages/backlog_app
set -euo pipefail

out="$PWD/fonts/BoardSymbols.ttf"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

gstatic=https://fonts.gstatic.com/s
curl -sSfo symbols.woff2 "$gstatic/notosanssymbols/v43/rP2up3q65FkAtHfwd-eIS2brbDN6gxP34F9jRRCe4W3gfQ8gb_VFRkzrbQ.woff2"
curl -sSfo symbols2.woff2 "$gstatic/notosanssymbols2/v24/I_uyMoGduATTei9eI8daxVHDyfisHr71-vrgfE71.woff2"
curl -sSfo math.woff2 "$gstatic/notosansmath/v15/7Aump_cpkSecTWaHRlH2hyV5UHkD-V048PW0.woff2"
curl -sSfLo mono.ttf \
  https://github.com/notofonts/notofonts.github.io/raw/main/fonts/NotoSansMono/unhinted/ttf/NotoSansMono-Regular.ttf

subset() { # source unicodes output
  pyftsubset "$1" --unicodes="$2" --output-file="$3" --layout-features= --no-hinting \
    --drop-tables+=GSUB,GPOS,GDEF,vhea,vmtx,VORG --name-IDs='*'
}
# Arrows, technical, enclosed alphanumerics, misc symbols, dingbats, arrows.
subset symbols.woff2 U+2190-21FF,U+2300-23FF,U+2460-24FF,U+2600-27BF,U+2B00-2BFF a.ttf
# Geometric shapes (▸ ▾ ● ◉ ■) and what Noto Sans Symbols lacks there.
subset symbols2.woff2 U+2300-23FF,U+25A0-25FF,U+2600-27BF,U+2B00-2BFF b.ttf
# Mathematical operators (⋯) and arrows (↻).
subset math.woff2 U+2190-21FF,U+2200-22FF,U+27C0-27FF,U+2900-2AFF c.ttf
# Box drawing (└) and block elements.
subset mono.ttf U+2500-259F d.ttf

pyftmerge a.ttf b.ttf c.ttf d.ttf --output-file=merged.ttf
python3 - merged.ttf "$out" <<'PY'
import sys
from fontTools.ttLib import TTFont
font = TTFont(sys.argv[1])
names = font["name"]
for record in list(names.names):
    if record.nameID in (1, 3, 4, 6, 16, 17):
        names.removeNames(nameID=record.nameID)
names.setName("Board Symbols", 1, 3, 1, 0x409)
names.setName("Board Symbols Regular", 4, 3, 1, 0x409)
names.setName("BoardSymbols-Regular", 3, 3, 1, 0x409)
names.setName("BoardSymbols-Regular", 6, 3, 1, 0x409)
names.setName("Copyright 2022 The Noto Project Authors (https://github.com/notofonts)", 0, 3, 1, 0x409)
font.save(sys.argv[2])
PY
echo "Wrote $out ($(wc -c <"$out") bytes)"
