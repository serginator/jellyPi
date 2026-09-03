#!/usr/bin/env bash
set -euo pipefail

STORAGE=/mnt/storage
OUT="backups/config-$(date +%Y%m%d-%H%M%S).tar.gz"
mkdir -p backups

echo "Stopping containers..."
docker compose stop

echo "Creating backup (excluding cache, metadata, logs)..."
tar czf "$OUT" \
  --exclude="mnt/storage/config/jellyfin/cache" \
  --exclude="mnt/storage/config/jellyfin/data/metadata" \
  --exclude="mnt/storage/config/jellyfin/data/transcodes" \
  --exclude="mnt/storage/config/jellyfin/log" \
  --exclude="*/logs" \
  -C / \
  "mnt/storage/config"

docker compose start
echo "Backup: $OUT ($(du -sh "$OUT" | cut -f1))"
echo "Copy this file off the Pi before reinstalling."
