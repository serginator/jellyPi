#!/bin/bash
# qBittorrent 5.x CSRF protection ignores LocalHostAuth bypass — login required.
# Reads QBITTORRENT_PASSWORD from .env at runtime so no secret is ever baked
# into this file (unlike setup.sh's old inline heredoc version).
DIR="$(cd "$(dirname "$0")" && pwd)"
set -a; source "$DIR/.env"; set +a

SID=$(curl -s -c /tmp/qbt.sid -d "username=admin&password=${QBITTORRENT_PASSWORD}" http://localhost:8080/api/v2/auth/login)
curl -s -b /tmp/qbt.sid -d "hashes=all" "http://localhost:8080/api/v2/torrents/$1"
