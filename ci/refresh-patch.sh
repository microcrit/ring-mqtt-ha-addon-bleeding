#!/usr/bin/env bash
# Refresh a patch file from a hand-edited CI-managed file.
# Usage: ci/refresh-patch.sh patches/<area>/<file>.patch
#
#   patches/ring-mqtt-src/*  regenerates from `git -C ring-mqtt-src diff`
#                            (hand-edit the submodule file first)
#   patches/ring-mqtt/*      regenerates as diff of
#                            upstream-addon/main:<file> vs worktree <file>
#                            (hand-edit ring-mqtt/<file> first); the
#                            auto-managed version line is normalized to
#                            upstream's value so it never leaks into the patch
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

patch="${1:?usage: refresh-patch.sh patches/<area>/<file>.patch}"

case "$patch" in
  patches/ring-mqtt-src/*)
    f="${patch#patches/ring-mqtt-src/}"
    git -C ring-mqtt-src diff -- "$f" > "$patch"
    ;;
  patches/ring-mqtt/*)
    # Target file comes from the patch's own +++ header, not the patch name.
    target="$(sed -n 's|^+++ b/||p' "$patch" | head -n1)"
    [[ -n "$target" ]] || { echo "error: no +++ b/ header in $patch" >&2; exit 1; }
    base="$(git show "upstream-addon/main:$target")"
    cur="$(cat "$target")"
    upver="$(printf '%s\n' "$base" | sed -n 's/^version: //p')"
    cur_norm="$(printf '%s\n' "$cur" | sed "s/^version: .*/version: ${upver}/")"
    printf '%s\n' "$base" > /tmp/rp-base.yaml
    printf '%s\n' "$cur_norm" > /tmp/rp-cur.yaml
    {
      printf 'diff --git a/%s b/%s\n' "$target" "$target"
      git hash-object -w /tmp/rp-base.yaml | tr -d '\n'
      printf '..'
      git hash-object -w /tmp/rp-cur.yaml | tr -d '\n'
      printf ' 100644\n'
      diff -u /tmp/rp-base.yaml /tmp/rp-cur.yaml \
        | sed "1s|.*|--- a/$target|;2s|.*|+++ b/$target|"
    } > "$patch"
    rm -f /tmp/rp-base.yaml /tmp/rp-cur.yaml
    ;;
  *)
    echo "unknown patch path: $patch" >&2
    exit 1
    ;;
esac

git apply --check "$patch" && echo "refreshed: $patch (applies clean)"
