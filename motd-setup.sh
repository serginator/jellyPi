#!/usr/bin/env bash
# Installs motd.txt as /etc/motd (the static part of the SSH login banner).
# Idempotent. Needs root. Color tokens in motd.txt are replaced by ANSI codes.
set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Run with: sudo ./motd-setup.sh"; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)/motd.txt"
E=$'\e'
sed -e "s/{tl}/${E}[38;5;43m/g" \
    -e "s/{pu}/${E}[38;5;105m/g" \
    -e "s/{dim}/${E}[2m/g" \
    -e "s/{r}/${E}[0m/g" "$SRC" > /etc/motd
echo "[flexPi] /etc/motd updated"
