#!/usr/bin/env bash
# Adds 3 Jellyfin plugin repositories, pre-writes their configurations, and
# prints instructions for installing them from the catalog.
# Run after `docker compose up -d` and after completing the Jellyfin setup wizard.
# Requires JELLYFIN_API_KEY, SEERR_API_KEY, SONARR_API_KEY, RADARR_API_KEY,
# and TMDB_API_KEY in .env.
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[plugins]${NC} $1"; }
warn() { echo -e "${YELLOW}[plugins]${NC} $1"; }
die()  { echo -e "${RED}[plugins]${NC} $1"; exit 1; }

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
[[ -f $ENV_FILE ]] || die "No .env found at $ENV_FILE"
set -a; source "$ENV_FILE"; set +a

: "${JELLYFIN_API_KEY:?Set JELLYFIN_API_KEY in .env (Dashboard → API Keys → +)}"
: "${SEERR_API_KEY:?Set SEERR_API_KEY in .env (Seerr → Settings → General → API Key)}"
: "${SONARR_API_KEY:?Set SONARR_API_KEY in .env}"
: "${RADARR_API_KEY:?Set RADARR_API_KEY in .env}"
: "${TMDB_API_KEY:?Set TMDB_API_KEY in .env (themoviedb.org → Account → API)}"

STORAGE="${STORAGE:-/mnt/storage}"
JF_URL="http://localhost:8096"
JF_AUTH="X-Emby-Authorization: MediaBrowser Token=\"${JELLYFIN_API_KEY}\""
PLUGINS_CONF="$STORAGE/config/jellyfin/data/plugins/configurations"

# ── 1. Add plugin repositories ─────────────────────────────────────────────────
log "Adding plugin repositories to Jellyfin..."

# POST /Repositories replaces the full list — include the default repo.
REPOS_JSON='[
  {"Name":"Jellyfin Stable","Url":"https://repo.jellyfin.org/files/plugin/manifest.json","Enabled":true},
  {"Name":"File Transformator","Url":"https://www.iamparadox.dev/jellyfin/plugins/manifest.json","Enabled":true},
  {"Name":"SeerrFin","Url":"https://raw.githubusercontent.com/varunaditya-plus/SeerrFin/main/manifest.json","Enabled":true},
  {"Name":"Moonbase","Url":"https://raw.githubusercontent.com/Moonfin-Client/Plugin/refs/heads/master/manifest.json","Enabled":true}
]'

curl -sf -X POST "$JF_URL/Repositories" \
    -H "$JF_AUTH" -H "Content-Type: application/json" \
    -d "$REPOS_JSON" \
    || die "Failed to add repositories. Is Jellyfin running and JELLYFIN_API_KEY correct?"

log "Repositories added."

# ── 2. Pre-write plugin configurations ─────────────────────────────────────────
log "Writing plugin configurations to $PLUGINS_CONF ..."
mkdir -p "$PLUGINS_CONF"

SEERR_CONF="$PLUGINS_CONF/Jellyfin.Plugin.SeerrFin.xml"
MOONBASE_CONF="$PLUGINS_CONF/Moonfin.Server.xml"

if [[ -f $SEERR_CONF ]]; then
    warn "SeerrFin config already exists, skipping (edit $SEERR_CONF manually if needed)"
else
    cat > "$SEERR_CONF" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <JellyseerrUrl>http://seerr:5055</JellyseerrUrl>
  <ExternalJellyseerrUrl>http://jellypi.local:5055</ExternalJellyseerrUrl>
  <JellyseerrApiKey>${SEERR_API_KEY}</JellyseerrApiKey>
  <RadarrUrl>http://radarr:7878</RadarrUrl>
  <RadarrApiKey>${RADARR_API_KEY}</RadarrApiKey>
  <SonarrUrl>http://sonarr:8989</SonarrUrl>
  <SonarrApiKey>${SONARR_API_KEY}</SonarrApiKey>
  <TmdbApiKey>${TMDB_API_KEY}</TmdbApiKey>
  <WatchRegion>US</WatchRegion>
  <JellyseerrPreferredLanguages>en</JellyseerrPreferredLanguages>
  <RowItemLimit>20</RowItemLimit>
  <CacheTimeoutSeconds>86400</CacheTimeoutSeconds>
  <AddSeerrResultsInSearch>true</AddSeerrResultsInSearch>
  <QualityRecommendations>true</QualityRecommendations>
</PluginConfiguration>
EOF
    chown 1000:1000 "$SEERR_CONF"
    log "SeerrFin config written."
fi

if [[ -f $MOONBASE_CONF ]]; then
    warn "Moonbase config already exists, skipping (edit $MOONBASE_CONF manually if needed)"
    MOONBASE_SECRET="<see existing config>"
else
    # Generate a random webhook secret for Moonbase ↔ Seerr integration.
    MOONBASE_SECRET=$(openssl rand -hex 16)
    cat > "$MOONBASE_CONF" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <EnableSettingsSync>true</EnableSettingsSync>
  <SeerrEnabled>true</SeerrEnabled>
  <SeerrUrl>http://seerr:5055</SeerrUrl>
  <JellyseerrEnabled>false</JellyseerrEnabled>
  <SeerrWebhookSecret>${MOONBASE_SECRET}</SeerrWebhookSecret>
  <TmdbApiKey>${TMDB_API_KEY}</TmdbApiKey>
  <MdblistOfficialListsEnabled>true</MdblistOfficialListsEnabled>
  <ImdbListsEnabled>true</ImdbListsEnabled>
  <StudioLogosEnabled>true</StudioLogosEnabled>
  <WebDefaultServerUrl>http://jellypi.local:8096</WebDefaultServerUrl>
  <WebEnableWebRtcScan>true</WebEnableWebRtcScan>
  <PushRelayUrl>https://push.moonfin.io/send</PushRelayUrl>
</PluginConfiguration>
EOF
    chown 1000:1000 "$MOONBASE_CONF"
    log "Moonbase config written."
fi

# ── 3. Next steps ──────────────────────────────────────────────────────────────
echo
warn "Next steps:"
warn "1. Go to Dashboard → Plugins → Catalog and install:"
warn "     - File Transformator  (by iamparadox)"
warn "     - SeerrFin            (by varunaditya)"
warn "     - Moonbase            (by Moonfin Client)"
warn "2. Restart Jellyfin so the plugins load:"
warn "     docker compose restart jellyfin"
warn "3. Configure the Moonbase webhook in Seerr:"
warn "   Seerr → Settings → Notifications → Webhook → Add Webhook"
warn "   URL: http://jellyfin:8096/Moonfin/webhook"
warn "   Auth header: X-Webhook-Secret: ${MOONBASE_SECRET}"
warn "   Events: Request approved, Request available, etc."
