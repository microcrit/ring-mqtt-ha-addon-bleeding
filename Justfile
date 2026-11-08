set shell := ["bash", "-euo", "pipefail", "-c"]

image := "docker.io/shellings/ring-mqtt-bleeding"

default:
    @just --list

sync:
    git pull --ff-only origin main
    git -C ring-mqtt-src fetch --quiet origin
    git -C ring-mqtt-src checkout --quiet main
    git -C ring-mqtt-src merge --ff-only --quiet origin/main

ci:
    bash ci/deploy.sh

status:
    bash ci/deploy.sh --status

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
