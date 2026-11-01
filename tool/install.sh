#!/usr/bin/env bash
# Installs backlog and backlog-server from this repository with Nix, as
# symlinks in ~/.local/bin pointing to a GC root in ~/.local/state/kanban-ai.
#
#   tool/install.sh [ref]   # backlog, backlog-server from a branch, tag or commit (default: main)
#   tool/install.sh --dev   # backlog-dev, backlog-server-dev from this worktree, uncommitted
#                           # changes of tracked files included
#
# KANBAN_AI_BIN_DIR and KANBAN_AI_STATE_DIR override the two folders.
set -euo pipefail

repo="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
bin="${KANBAN_AI_BIN_DIR:-$HOME/.local/bin}"
state="${KANBAN_AI_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/kanban-ai}"

if [[ "${1:-}" == "--dev" ]]; then
  suffix=-dev
  link="$state/dev"
  flake="git+file://$repo"
  sha="$(git -C "$repo" rev-parse HEAD)"
  from="worktree $repo ($(git -C "$repo" branch --show-current || true) at ${sha:0:12}"
  if [[ -n "$(git -C "$repo" status --porcelain --untracked-files=no)" ]]; then from+=", with uncommitted changes"; fi
  from+=")"
else
  ref="${1:-main}"
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
echo "Building kanban-ai from $from …"
nix build --out-link "$link" "$flake#kanban-ai"
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
