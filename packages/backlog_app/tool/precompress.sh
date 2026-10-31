#!/usr/bin/env bash
# Writes Brotli (.br) and gzip (.gz) copies next to the compressible files of
# a built web app (default: build/web), which backlog-server sends to browsers
# that accept them. Files under 1 kB and debug symbols are skipped. Brotli is
# optional: without the `brotli` tool only gzip copies are made.
#
#   tool/precompress.sh [dir]
set -euo pipefail

dir="${1:-build/web}"
if [[ ! -d "$dir" ]]; then
  echo "precompress: no folder $dir" >&2
  exit 1
fi
if command -v brotli >/dev/null; then
  export PRECOMPRESS_BROTLI=1
else
  export PRECOMPRESS_BROTLI=
  echo "precompress: brotli not found, making gzip copies only" >&2
fi

compress() {
  local file
  for file in "$@"; do
    gzip -9 -n -c "$file" >"$file.gz"
    # As old as the original: the server ignores copies older than it.
    touch -r "$file" "$file.gz"
    if [[ -n "$PRECOMPRESS_BROTLI" ]]; then
      brotli -q 11 -f -o "$file.br" "$file"
      touch -r "$file" "$file.br"
    fi
  done
}
export -f compress

find "$dir" -type f -size +1023c \
  \( -name '*.js' -o -name '*.mjs' -o -name '*.wasm' -o -name '*.json' -o -name '*.html' -o -name '*.css' \
  -o -name '*.svg' -o -name '*.txt' -o -name '*.ttf' -o -name '*.otf' \) -print0 |
  xargs -0 -r -n 1 -P "$(nproc 2>/dev/null || echo 4)" bash -c 'compress "$@"' _
echo "precompress: compressed the web app in $dir"
