#!/usr/bin/env bash
set -euo pipefail

STORAGE=/mnt/storage
BACKUP=${1:-}

[[ -z "$BACKUP" ]] && { echo "Usage: ./restore.sh <backup.tar.gz>"; exit 1; }
[[ -f "$BACKUP" ]] || { echo "File not found: $BACKUP"; exit 1; }

if ! command -v sqlite3 &>/dev/null; then
  echo "Installing sqlite3..."
  sudo apt-get install -y sqlite3
fi

echo "Stopping containers..."
docker compose down

echo "Extracting config..."
tar xzf "$BACKUP" -C /

echo "Stripping library data from Sonarr/Radarr (settings kept)..."

SONARR_DB="$STORAGE/config/sonarr/sonarr.db"
if [[ -f "$SONARR_DB" ]]; then
  sqlite3 "$SONARR_DB" \
    "DELETE FROM Series; DELETE FROM Episodes; DELETE FROM EpisodeFiles; DELETE FROM History; DELETE FROM Blocklist; DELETE FROM PendingReleases;" \
    2>/dev/null || true
  echo "  Sonarr: library cleared"
fi

RADARR_DB="$STORAGE/config/radarr/radarr.db"
if [[ -f "$RADARR_DB" ]]; then
  sqlite3 "$RADARR_DB" \
    "DELETE FROM Movies; DELETE FROM MovieFiles; DELETE FROM History; DELETE FROM Blocklist; DELETE FROM PendingReleases;" \
    2>/dev/null || true
  echo "  Radarr: library cleared"
fi

echo "Starting containers..."
docker compose up -d
echo ""
echo "Done. What to do next:"
echo "  1. Add series/movies via Seerr:    http://jellypi.local:5055"
echo "  2. Scan libraries in Jellyfin:     http://jellypi.local:8096"
echo "  3. Verify Tailscale:               docker exec tailscale tailscale status"
