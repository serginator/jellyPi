#!/usr/bin/env bash
# Triggered at 18:05 Mon-Fri to retry any Sonarr/Radarr grabs that failed while qBittorrent was stopped.
set -euo pipefail

STORAGE=/mnt/storage

SONARR_KEY=$(grep -o "<ApiKey>[^<]*</ApiKey>" "$STORAGE/config/sonarr/config.xml" | sed 's/<[^>]*>//g')
curl -s -X POST "http://localhost:8989/api/v3/command" \
  -H "X-Api-Key: $SONARR_KEY" -H "Content-Type: application/json" \
  -d '{"name":"MissingEpisodeSearch"}'

RADARR_KEY=$(grep -o "<ApiKey>[^<]*</ApiKey>" "$STORAGE/config/radarr/config.xml" | sed 's/<[^>]*>//g')
curl -s -X POST "http://localhost:7878/api/v3/command" \
  -H "X-Api-Key: $RADARR_KEY" -H "Content-Type: application/json" \
  -d '{"name":"MissingMoviesSearch"}'
