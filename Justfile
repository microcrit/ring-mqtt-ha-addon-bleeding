set shell := ["bash", "-euo", "pipefail", "-c"]

# Build/push image name must match `image:` in ring-mqtt/config.yaml
image := "docker.io/shellings/ring-mqtt-bleeding"

default:
    @just --list

# Sync repo + upstream addon repo + submodule, apply patch series (no build)
sync:
    bash ci/deploy.sh --sync

# Full CI: sync, multi-arch build (amd64+arm64) via podman, push, bump version, commit
ci:
    bash ci/deploy.sh

# Report whether anything changed (no build/push/commit)
status:
    bash ci/deploy.sh --status

# Show current patch series (checks against current worktree state;
# ring-mqtt/ checks normalize CI's version bump out of the way first)
patches:
    @ls -1 patches/*/*.patch
    @for p in patches/*/*.patch; do \
        echo "=== $p"; \
        abs="$PWD/$p"; tmp=""; \
        case "$p" in \
          patches/ring-mqtt-src/*) \
            g="git -C ring-mqtt-src apply"; args="$abs" ;; \
          *) \
            target="$(sed -n 's|^+++ b/||p' "$abs" | head -n1)"; \
            tmp="$(mktemp -d)"; mkdir -p "$tmp/$(dirname "$target")"; \
            upver="$(git show "upstream-addon/main:$target" | sed -n 's/^version: //p')"; \
            sed "s/^version: .*/version: $upver/" "$target" > "$tmp/$target"; \
            g="git apply"; args="--directory=$tmp --unsafe-paths $abs" ;; \
        esac; \
        if $g --check $args >/dev/null 2>&1; then echo "state: applies clean (not yet applied)"; \
        elif $g --reverse --check $args >/dev/null 2>&1; then echo "state: already applied"; \
        else echo "state: CONFLICT (refresh needed)"; fi; \
        [ -z "$tmp" ] || rm -rf "$tmp"; \
    done

# Refresh a patch from hand-edited CI-managed files:
#   1. edit ring-mqtt-src/Dockerfile (submodule) or ring-mqtt/config.yaml
#   2. just refresh-patch patches/<area>/<file>.patch
#   3. revert the hand edit (git checkout -- <file>); CI re-applies from patch
refresh-patch patch:
    bash ci/refresh-patch.sh "{{patch}}"

# Install + start the daily systemd user timer
install-timer:
    mkdir -p ~/.config/systemd/user
    install -m644 ci/ring-mqtt-bleeding.service ci/ring-mqtt-bleeding.timer ~/.config/systemd/user/
    systemctl --user daemon-reload
    systemctl --user enable --now ring-mqtt-bleeding.timer
    systemctl --user list-timers ring-mqtt-bleeding.timer --no-pager

uninstall-timer:
    systemctl --user disable --now ring-mqtt-bleeding.timer || true
    rm -f ~/.config/systemd/user/ring-mqtt-bleeding.{service,timer}
    systemctl --user daemon-reload

timer-status:
    systemctl --user status ring-mqtt-bleeding.timer --no-pager || true
    systemctl --user list-timers ring-mqtt-bleeding.timer --no-pager || true
