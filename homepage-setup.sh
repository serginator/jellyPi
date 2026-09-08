#!/usr/bin/env bash
# Generates Homepage's config files (services.yaml, widgets.yaml, settings.yaml,
# bookmarks.yaml) from .env — run after Sonarr/Radarr/Prowlarr have started at
# least once (their API keys don't exist until then, same requirement as
# post-setup.sh). Safe to re-run any time to pick up new keys from .env —
# e.g. add JELLYFIN_API_KEY/SEERR_API_KEY later to turn those links into widgets.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
[[ -f $ENV_FILE ]] || { echo "No se encontró $ENV_FILE"; exit 1; }
set -a; source "$ENV_FILE"; set +a

STORAGE=${STORAGE:-/mnt/storage}
: "${SONARR_API_KEY:?Falta SONARR_API_KEY en .env — arranca sonarr y ejecuta post-setup.sh primero}"
: "${RADARR_API_KEY:?Falta RADARR_API_KEY en .env — arranca radarr y ejecuta post-setup.sh primero}"
: "${QBITTORRENT_PASSWORD:?Falta QBITTORRENT_PASSWORD en .env}"

CONFIG_DIR="$STORAGE/config/homepage"
mkdir -p "$CONFIG_DIR"

# Prowlarr shares the Servarr config.xml format, so its key can be read the
# same way post-setup.sh reads Sonarr/Radarr's — no need to store it in .env.
PROWLARR_CONFIG="$STORAGE/config/prowlarr/config.xml"
if [[ -f $PROWLARR_CONFIG ]]; then
    PROWLARR_API_KEY=$(grep -o "<ApiKey>[^<]*</ApiKey>" "$PROWLARR_CONFIG" | sed "s/<[^>]*>//g")
else
    echo "Prowlarr no ha arrancado todavía, omito su widget (solo tendrá el enlace)."
    PROWLARR_API_KEY=""
fi

# Jellyfin and seerr don't auto-generate an API key like the Servarr apps
# do, so these stay link-only unless you create one yourself and add it to
# .env — see README "Homepage" section.
JELLYFIN_API_KEY="${JELLYFIN_API_KEY:-}"
SEERR_API_KEY="${SEERR_API_KEY:-}"
[[ -z $JELLYFIN_API_KEY ]] && echo "JELLYFIN_API_KEY no está en .env, omito su widget (solo tendrá el enlace)."
[[ -z $SEERR_API_KEY ]] && echo "SEERR_API_KEY no está en .env, omito su widget (solo tendrá el enlace)."

cat > "$CONFIG_DIR/settings.yaml" <<'EOF'
title: jellyPi
theme: dark
color: slate
headerStyle: clean
layout:
  Media:
    style: row
    columns: 2
  Downloads & Automation:
    style: row
    columns: 3
  System:
    style: row
    columns: 3
EOF

cat > "$CONFIG_DIR/widgets.yaml" <<'EOF'
- resources:
    label: Pi
    cpu: true
    memory: true
    disk: /
- resources:
    label: HDD
    disk: /mnt/storage
- search:
    provider: duckduckgo
    target: _blank
EOF

cat > "$CONFIG_DIR/bookmarks.yaml" <<'EOF'
EOF

# Required for every "server: localhost" reference in services.yaml — Homepage
# has no implicit default docker instance, so without this file it errors with
# "Cannot read properties of null (reading 'localhost')".
cat > "$CONFIG_DIR/docker.yaml" <<'EOF'
localhost:
  socket: /var/run/docker.sock
EOF

cat > "$CONFIG_DIR/services.yaml" <<EOF
- Media:
    - Jellyfin:
        icon: jellyfin.png
        href: http://jellypi.local:8096
        description: Movies, TV and anime
        server: localhost
        container: jellyfin
$( [[ -n $JELLYFIN_API_KEY ]] && cat <<EOF2
        widgets:
          - type: jellyfin
            url: http://jellyfin:8096
            key: "${JELLYFIN_API_KEY}"
            version: 2
            enableNowPlaying: true
EOF2
)
    - Seerr:
        icon: overseerr.png
        href: http://jellypi.local:5055
        description: Request movies and shows
        server: localhost
        container: seerr
$( [[ -n $SEERR_API_KEY ]] && cat <<EOF2
        widgets:
          - type: seerr
            url: http://seerr:5055
            key: "${SEERR_API_KEY}"
EOF2
)

- Downloads & Automation:
    - qBittorrent:
        icon: qbittorrent.png
        href: http://jellypi.local:8080
        description: Torrent client (via Gluetun VPN)
        server: localhost
        container: qbittorrent
        widgets:
          - type: qbittorrent
            url: http://gluetun:8080
            username: admin
            password: "${QBITTORRENT_PASSWORD}"
            enableLeechProgress: true

    - Sonarr:
        icon: sonarr.png
        href: http://jellypi.local:8989
        description: TV shows automation
        server: localhost
        container: sonarr
        widgets:
          - type: sonarr
            url: http://sonarr:8989
            key: "${SONARR_API_KEY}"

    - Radarr:
        icon: radarr.png
        href: http://jellypi.local:7878
        description: Movies automation
        server: localhost
        container: radarr
        widgets:
          - type: radarr
            url: http://radarr:7878
            key: "${RADARR_API_KEY}"

    - Prowlarr:
        icon: prowlarr.png
        href: http://jellypi.local:9696
        description: Indexer manager
        server: localhost
        container: prowlarr
$( [[ -n $PROWLARR_API_KEY ]] && cat <<EOF2
        widgets:
          - type: prowlarr
            url: http://prowlarr:9696
            key: "${PROWLARR_API_KEY}"
EOF2
)
    - Bazarr:
        icon: bazarr.png
        href: http://jellypi.local:6767
        description: Subtitles automation
        server: localhost
        container: bazarr

- System:
    - Uptime Kuma:
        icon: uptime-kuma.png
        href: http://jellypi.local:3001
        description: Service monitoring
        server: localhost
        container: uptime-kuma

    - FlareSolverr:
        icon: flaresolverr.png
        description: Cloudflare bypass for indexers
        server: localhost
        container: flaresolverr

    - Gluetun:
        icon: gluetun.png
        description: VPN for qBittorrent
        server: localhost
        container: gluetun
EOF

chmod 600 "$CONFIG_DIR/services.yaml"

echo "Config de Homepage generada en $CONFIG_DIR"
echo "Aplica los cambios con: docker compose restart homepage"
echo "(igual que decluttarr: 'up -d' no basta, no detecta cambios en archivos montados por bind mount)"
