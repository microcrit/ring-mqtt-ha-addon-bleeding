#!/usr/bin/env bash
# CI: sync this repo + ring-mqtt-src submodule, build multi-arch image with a
# git-hash version tag, push to Docker Hub, bump ring-mqtt/config.yaml version
# and push the bump back to GitHub.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

IMAGE="docker.io/shellings/ring-mqtt-bleeding"
STATE_FILE="$REPO/.ci-state"          # last successfully deployed ring-mqtt-src sha
PLATFORMS="linux/amd64,linux/arm64"

log() { printf '[deploy] %s\n' "$*"; }

# ---------------------------------------------------------------- sync
log "pulling addon repo (origin main)"
git pull --ff-only origin main

log "syncing ring-mqtt-src submodule to upstream main"
git -C ring-mqtt-src fetch --quiet origin
git -C ring-mqtt-src checkout --quiet main
git -C ring-mqtt-src merge --ff-only --quiet origin/main

SUB_SHA="$(git -C ring-mqtt-src rev-parse HEAD)"
BASE_VERSION="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' ring-mqtt-src/package.json | head -n1)"
[[ -n "$BASE_VERSION" ]] || { echo "error: could not read version from ring-mqtt-src/package.json" >&2; exit 1; }
VERSION="${BASE_VERSION}-git-${SUB_SHA}"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log "ring-mqtt-src at $SUB_SHA -> version $VERSION"

if [[ "${1:-}" == "--status" ]]; then
    last="$(cat "$STATE_FILE" 2>/dev/null || echo none)"
    log "last deployed: $last"
    [[ "$last" == "$SUB_SHA" ]] && log "up to date, no build needed" || log "changed, run 'just ci' to deploy"
    exit 0
fi

if [[ -f "$STATE_FILE" && "$(cat "$STATE_FILE")" == "$SUB_SHA" ]]; then
    log "ring-mqtt-src unchanged since last deploy; nothing to do"
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

# ------------------------------------------------- bump addon version
# Refuse if something is already staged: the commit below must contain only
# the version bump + submodule pointer, never unrelated local work.
if ! git diff --cached --quiet; then
    echo "error: staged changes present in index; commit or unstage them first" >&2
    exit 1
fi

# Stage a version-bump blob derived from HEAD so uncommitted local edits to
# ring-mqtt/config.yaml (e.g. display-name tweaks) are NOT swept into the
# automated commit; the worktree file keeps those edits.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
git show HEAD:ring-mqtt/config.yaml | sed "s/^version: .*/version: $VERSION/" > "$tmp"
blob="$(git hash-object -w "$tmp")"
git update-index --cacheinfo "100644,$blob,ring-mqtt/config.yaml"
# Keep the worktree copy in sync too (only the version line changes there).
sed -i "s/^version: .*/version: $VERSION/" ring-mqtt/config.yaml
git add ring-mqtt-src

if git diff --cached --quiet; then
    log "repo already carries version $VERSION; nothing to commit"
else
    git commit --quiet -m "deploy: $VERSION ($BUILD_DATE)"
    git push --quiet origin main
    log "committed and pushed version bump to GitHub"
fi

printf '%s\n' "$SUB_SHA" > "$STATE_FILE"
log "done: $VERSION"
