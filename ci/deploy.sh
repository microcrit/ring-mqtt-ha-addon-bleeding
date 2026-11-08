#!/usr/bin/env bash
# CI: sync this repo + upstream addon repo + ring-mqtt-src submodule, apply our
# patch series, build multi-arch image with a git-hash version tag, push to
# Docker Hub, bump ring-mqtt/config.yaml version and push back to GitHub.
#
# Modes:
#   (none)    sync + patch + build + push + commit   (default, used by timer)
#   --sync    sync + patch only, leave worktree dirty for inspection
#   --status  report whether anything changed, touch nothing
#
# ring-mqtt/ is CI-managed: every run re-baselines it from
# tsightler/ring-mqtt-ha-addon and re-applies patches/ring-mqtt/*.patch.
# Never edit ring-mqtt/ by hand — edit the patches instead.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

IMAGE="docker.io/shellings/ring-mqtt-bleeding"
STATE_FILE="$REPO/.ci-state"    # "<subsha> <upstream-addon sha> <patch hash>"
PLATFORMS="linux/amd64,linux/arm64"
UPSTREAM_ADDON_URL="https://github.com/tsightler/ring-mqtt-ha-addon"

log() { printf '[deploy] %s\n' "$*"; }

MODE="deploy"
case "${1:-}" in
    "") ;;
    --sync)   MODE="sync" ;;
    --status) MODE="status" ;;
    *) echo "usage: $0 [--sync|--status]" >&2; exit 2 ;;
esac

PATCH_HASH="$({ cat patches/*/*.patch 2>/dev/null || true; } | sha256sum | cut -d' ' -f1)"

# ---------------------------------------------------------------- status
# Read-only: fetches update remote-tracking refs only, never the worktree.
if [[ "$MODE" == "status" ]]; then
    log "fetching (read-only)"
    git fetch --quiet origin
    if ! git remote get-url upstream-addon >/dev/null 2>&1; then
        git remote add upstream-addon "$UPSTREAM_ADDON_URL"
    fi
    git fetch --quiet upstream-addon
    git -C ring-mqtt-src fetch --quiet origin

    SUB_SHA="$(git -C ring-mqtt-src rev-parse origin/dev)"
    UP_SHA="$(git rev-parse upstream-addon/main)"
    STATE="$SUB_SHA $UP_SHA $PATCH_HASH"
    LAST="$(cat "$STATE_FILE" 2>/dev/null || echo none)"
    log "ring-mqtt-src:  $SUB_SHA (origin/dev)"
    log "upstream-addon: $UP_SHA"
    log "patches:        ${PATCH_HASH:0:16}…"
    log "last deployed:  $LAST"
    if [[ "$LAST" == "$STATE" ]]; then
        log "up to date, no build needed"
    else
        log "changed, run 'just ci' to deploy"
    fi
    exit 0
fi

# A previous failed or --sync run may have left ring-mqtt/ half-rebaselined
# (checkout stages the baseline); drop it so git pull can't be blocked and the
# staged-refusal below only sees genuinely unrelated work. ring-mqtt/ is
# CI-managed, see header.
git restore --staged --worktree -- ring-mqtt/ 2>/dev/null || true

# Refuse if something unrelated is staged: our commits must contain only
# CI-managed paths (ring-mqtt/, ring-mqtt-src pointer).
if ! git diff --cached --quiet; then
    echo "error: staged changes present in index; commit or unstage them first" >&2
    exit 1
fi

# ---------------------------------------------------------------- sync
log "pulling addon repo (origin main)"
git pull --ff-only origin main

if ! git remote get-url upstream-addon >/dev/null 2>&1; then
    git remote add upstream-addon "$UPSTREAM_ADDON_URL"
fi
log "fetching upstream addon repo (tsightler/ring-mqtt-ha-addon)"
git fetch --quiet upstream-addon

# Submodule is pristine-upstream between runs: reset drops patches applied by
# the previous run, then fast-forward to upstream dev.
log "syncing ring-mqtt-src submodule to upstream dev"
git -C ring-mqtt-src fetch --quiet origin
git -C ring-mqtt-src checkout --quiet dev
git -C ring-mqtt-src reset --quiet --hard origin/dev

SUB_SHA="$(git -C ring-mqtt-src rev-parse HEAD)"
UP_SHA="$(git rev-parse upstream-addon/main)"
BASE_VERSION="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' ring-mqtt-src/package.json | head -n1)"
[[ -n "$BASE_VERSION" ]] || { echo "error: could not read version from ring-mqtt-src/package.json" >&2; exit 1; }
VERSION="${BASE_VERSION}-git-${SUB_SHA}"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STATE="$SUB_SHA $UP_SHA $PATCH_HASH"
LAST="$(cat "$STATE_FILE" 2>/dev/null || echo none)"

if [[ "$LAST" == "$STATE" ]]; then
    log "nothing changed since last deploy (submodule, upstream addon, patches all same)"
    exit 0
fi

# --------------------------------------------------------- apply patches
apply_patch() {  # $1 = dir to apply in, $2 = patch file (repo-relative)
    local dir="$1" p="$2"
    log "applying $p"
    if git -C "$dir" apply --check "$REPO/$p" 2>/dev/null; then
        git -C "$dir" apply "$REPO/$p"
    elif git -C "$dir" apply --3way "$REPO/$p"; then
        # --3way implies --index; keep the index clean so only the parent
        # repo's gitadd decides what gets committed.
        git -C "$dir" reset --quiet
    else
        echo "error: patch $p no longer applies; refresh it against upstream" >&2
        exit 1
    fi
}

apply_patch ring-mqtt-src patches/ring-mqtt-src/0001-restore-jq.patch

# Re-baseline ring-mqtt/ from the upstream addon repo, then re-apply our
# customizations. checkout also stages the baseline; the final git add below
# re-syncs the index with the patched + version-bumped worktree.
log "re-baselining ring-mqtt/ from upstream-addon/main"
git checkout upstream-addon/main -- ring-mqtt/
apply_patch . patches/ring-mqtt/0001-bleeding-customizations.patch
sed -i "s/^version: .*/version: $VERSION/" ring-mqtt/config.yaml

if [[ "$MODE" == "sync" ]]; then
    log "sync complete (no build); inspect with: git diff"
    exit 0
fi

# ------------------------------------------------------- registry auth
if ! podman login --get-login docker.io >/dev/null 2>&1; then
    echo "error: not logged in to docker.io; run: podman login docker.io" >&2
    exit 1
fi

# ------------------------------------------------------------- build
# podman build with a comma-separated --platform overwrites the tag after each
# arch, so build each arch to its own tag and assemble manifest lists below.
build_args=(
    --build-arg BUILD_VERSION="$VERSION"
    --build-arg BUILD_DATE="$BUILD_DATE"
)
for plat in ${PLATFORMS//,/ }; do
    arch="${plat#*/}"
    log "building $IMAGE:$VERSION-$arch ($plat, built $BUILD_DATE)"
    podman build \
        --platform "$plat" \
        "${build_args[@]}" \
        -t "$IMAGE:$VERSION-$arch" \
        ring-mqtt-src
done

# ------------------------------------------------------- manifest lists
# Rebuild the lists from scratch each run: drop stale plain-image or manifest
# tags first (podman build --platform overwrites tags with plain images).
for tag in "$VERSION" latest; do
    if podman manifest exists "$IMAGE:$tag" 2>/dev/null; then
        podman manifest rm "$IMAGE:$tag" >/dev/null
    elif podman image exists "$IMAGE:$tag"; then
        podman rmi "$IMAGE:$tag" >/dev/null
    fi
    podman manifest create "$IMAGE:$tag" \
        "$IMAGE:$VERSION-amd64" "$IMAGE:$VERSION-arm64"
done

# ------------------------------------------------------------- push
for tag in "$VERSION" latest; do
    log "pushing $IMAGE:$tag"
    podman manifest push "$IMAGE:$tag" "docker://$IMAGE:$tag"
done
podman rmi "$IMAGE:$VERSION-amd64" "$IMAGE:$VERSION-arm64" >/dev/null || true

# ------------------------------------------------- commit version bump
git add -A ring-mqtt/
git add ring-mqtt-src

if git diff --cached --quiet; then
    log "repo already carries version $VERSION; nothing to commit"
else
    git commit --quiet -m "deploy: $VERSION ($BUILD_DATE)"
    git push --quiet origin main
    log "committed and pushed version bump to GitHub"
fi

printf '%s\n' "$STATE" > "$STATE_FILE"
log "done: $VERSION"
