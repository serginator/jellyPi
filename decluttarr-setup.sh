#!/usr/bin/env bash
# Generates decluttarr's config.yaml from .env — decluttarr v2+ dropped support for
# per-service environment variables (SONARR_KEY, RADARR_KEY, ...) in favor of a
# mounted config.yaml. Run this after Sonarr/Radarr have started at least once
# (their API keys don't exist until then) and .env has real values.
set -euo pipefail

STORAGE=/mnt/storage
DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
[[ -f $ENV_FILE ]] || { echo "No se encontró $ENV_FILE"; exit 1; }
set -a; source "$ENV_FILE"; set +a

: "${SONARR_API_KEY:?Falta SONARR_API_KEY en .env}"
: "${RADARR_API_KEY:?Falta RADARR_API_KEY en .env}"
: "${QBITTORRENT_PASSWORD:?Falta QBITTORRENT_PASSWORD en .env}"

CONFIG_DIR="$STORAGE/config/decluttarr"
mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_DIR/config.yaml" <<EOF
general:
  log_level: INFO
  test_run: false

job_defaults:
  max_strikes: 3
  min_days_between_searches: 7
  max_concurrent_searches: 3

jobs:
  remove_stalled:
  remove_failed_downloads:
  remove_failed_imports:
  remove_metadata_missing:
  remove_missing_files:
  remove_orphans:
  remove_unmonitored:

instances:
  sonarr:
    - base_url: "http://sonarr:8989"
      api_key: "${SONARR_API_KEY}"
  radarr:
    - base_url: "http://radarr:7878"
      api_key: "${RADARR_API_KEY}"

download_clients:
  qbittorrent:
    - base_url: "http://gluetun:8080"
      username: "admin"
      password: "${QBITTORRENT_PASSWORD}"
      name: "qBittorrent"
    - base_url: "http://gluetun:8080"
      username: "admin"
      password: "${QBITTORRENT_PASSWORD}"
      name: "qBittorrent-anime"
EOF

chmod 600 "$CONFIG_DIR/config.yaml"

echo "config.yaml de decluttarr generado en $CONFIG_DIR/config.yaml"
echo "Aplica los cambios con: docker compose restart decluttarr"
echo "(docker compose up -d no basta si el contenedor ya existía: no detecta cambios en el contenido del config.yaml montado, solo reinicia el proceso con 'restart')"
