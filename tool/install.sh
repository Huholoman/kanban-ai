#!/usr/bin/env bash
# Installs backlog and backlog-server from this repository as symlinks in
# ~/.local/bin pointing into ~/.local/state/kanban-ai.
#
#   tool/install.sh [ref]       # backlog, backlog-server from a branch, tag or commit (default: main),
#                               # built with Nix (a GC root)
#   tool/install.sh --dev       # backlog-dev, backlog-server-dev from this worktree as it is (uncommitted
#                               # changes included), built with the Dart and Flutter on the PATH (mise),
#                               # the web app and both programs in parallel, without Nix
#   tool/install.sh --dev --nix # the same from this worktree with Nix (uncommitted changes of tracked files)
#
# KANBAN_AI_BIN_DIR and KANBAN_AI_STATE_DIR override the two folders.
set -euo pipefail

repo="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
bin="${KANBAN_AI_BIN_DIR:-$HOME/.local/bin}"
state="${KANBAN_AI_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/kanban-ai}"

dev=
nix=
ref=main
for arg in "$@"; do
  case "$arg" in
    --dev) dev=1 ;;
    --nix) nix=1 ;;
    -*)
      echo "install: unknown option $arg" >&2
      exit 64
      ;;
    *) ref="$arg" ;;
  esac
done
# Releases always come from Nix; --dev builds locally unless --nix is given.
if [[ -z "$dev" ]]; then nix=1; fi
if [[ -z "$nix" ]] && ! { command -v dart && command -v flutter; } >/dev/null; then
  echo "install: dart and flutter must be on the PATH (mise run install-dev), or use --nix" >&2
  exit 1
fi

if [[ -n "$dev" ]]; then
  suffix=-dev
  link="$state/dev"
  flake="git+file://$repo"
  sha="$(git -C "$repo" rev-parse HEAD)"
  from="worktree $repo ($(git -C "$repo" branch --show-current || true) at ${sha:0:12}"
  if [[ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]]; then from+=", with uncommitted changes"; fi
  from+=")"
else
  suffix=
  link="$state/release"
  if ! sha="$(git -C "$repo" rev-parse --verify --quiet "$ref^{commit}")"; then
    echo "install: unknown branch, tag or commit: $ref" >&2
    exit 1
  fi
  flake="git+file://$repo?rev=$sha"
  from="$ref (${sha:0:12}) of $repo"
fi

mkdir -p "$bin" "$state"

# Builds into a new folder of $state/dev-local and points $link at it once
# everything is built, so a running server keeps its programs and web app
# until then. The previous build stays (a server may still run from it).
build_local() {
  local builds="$state/dev-local" out pids=() pid failed=
  mkdir -p "$builds"
  out="$(mktemp -d "$builds/$(date +%Y%m%d-%H%M%S)-${sha:0:12}-XXXX")"
  mkdir -p "$out/bin" "$out/libexec" "$out/logs"
  (cd "$repo" && dart pub get >/dev/null)
  (cd "$repo/packages/backlog_app" && flutter pub get >/dev/null)

  (cd "$repo/packages/backlog_app" &&
    flutter build web --release --no-pub --no-web-resources-cdn --pwa-strategy=none --output "$out/web" &&
    tool/precompress.sh "$out/web") >"$out/logs/web.log" 2>&1 &
  pids+=("$!:web")
  (cd "$repo" && dart compile exe packages/backlog_cli/bin/backlog.dart -o "$out/bin/backlog") \
    >"$out/logs/backlog.log" 2>&1 &
  pids+=("$!:backlog")
  (cd "$repo" && dart compile exe packages/backlog_server/bin/backlog_server.dart -o "$out/libexec/backlog-server") \
    >"$out/logs/backlog-server.log" 2>&1 &
  pids+=("$!:backlog-server")

  for pid in "${pids[@]}"; do
    if wait "${pid%%:*}"; then
      echo "  built ${pid#*:}"
    else
      echo "install: building ${pid#*:} failed:" >&2
      tail -n 40 "$out/logs/${pid#*:}.log" >&2
      failed=1
    fi
  done
  if [[ -n "$failed" ]]; then
    rm -rf "$out"
    exit 1
  fi

  # Like the Nix wrapper: the server serves its own web app unless told otherwise.
  cat >"$out/bin/backlog-server" <<EOF
#!/bin/sh
export BACKLOG_WEB="\${BACKLOG_WEB:-$out/web}"
exec "$out/libexec/backlog-server" "\$@"
EOF
  chmod +x "$out/bin/backlog-server"

  ln -sfn "$out" "$link"
  # Keep the new build and the one before it.
  find "$builds" -mindepth 1 -maxdepth 1 -type d ! -newer "$out" ! -path "$out" -printf '%T@ %p\n' |
    sort -rn | tail -n +2 | cut -d' ' -f2- | xargs -r rm -rf
}

if [[ -n "$nix" ]]; then
  echo "Building kanban-ai from $from with Nix …"
  nix build --max-jobs auto --out-link "$link" "$flake#kanban-ai"
else
  echo "Building kanban-ai from $from (web app, backlog, backlog-server in parallel) …"
  build_local
fi
# What it was built from, for `backlog config` › Global › Doctor.
echo "$from, $(date '+%Y-%m-%d %H:%M')" >"$link.txt"

for tool in backlog backlog-server; do
  ln -sfn "$link/bin/$tool" "$bin/$tool$suffix"
done

echo "Installed from $from:"
for tool in backlog backlog-server; do
  echo "  $bin/$tool$suffix -> $(readlink -f "$link")/bin/$tool"
done
if [[ ":$PATH:" != *":$bin:"* ]]; then echo "Note: $bin is not on PATH." >&2; fi
