#!/usr/bin/env bash
# Adds 3 Jellyfin plugin repositories, installs the plugins via API,
# pre-writes their configurations, and restarts Jellyfin.
# Run after `docker compose up -d` and after completing the Jellyfin setup wizard.
# Requires JELLYFIN_API_KEY, SEERR_API_KEY, SONARR_API_KEY, RADARR_API_KEY,
# and TMDB_API_KEY in .env.
# Only remaining manual step: configure the Moonbase webhook in Seerr.
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

# ── 2. Install plugins via API ─────────────────────────────────────────────────
log "Installing plugins..."

MANIFEST_URLS=(
    "https://www.iamparadox.dev/jellyfin/plugins/manifest.json"
    "https://raw.githubusercontent.com/varunaditya-plus/SeerrFin/main/manifest.json"
    "https://raw.githubusercontent.com/Moonfin-Client/Plugin/refs/heads/master/manifest.json"
)

python3 - "${MANIFEST_URLS[@]}" <<PYEOF
import json, sys, urllib.request, urllib.parse

JF_URL = "http://localhost:8096"
API_KEY = "$(echo "$JELLYFIN_API_KEY" | sed "s/\"/\\\\\"/g")"
HEADERS = {
    "X-Emby-Authorization": f'MediaBrowser Token="{API_KEY}"',
    "Content-Type": "application/json",
}

for manifest_url in sys.argv[1:]:
    try:
        data = json.loads(urllib.request.urlopen(manifest_url, timeout=15).read())
        pkg = data[0]
        name    = pkg["name"]
        guid    = pkg["guid"]
        version = pkg["versions"][0]["version"]
        url = (f"{JF_URL}/Packages/Installed/{urllib.parse.quote(name)}"
               f"?assemblyGuid={guid}&version={version}")
        req = urllib.request.Request(url, data=b"", method="POST")
        for k, v in HEADERS.items():
            req.add_header(k, v)
        urllib.request.urlopen(req)
        print(f"[plugins] Installed: {name} v{version}")
    except Exception as e:
        print(f"[plugins] ERROR installing from {manifest_url}: {e}", file=sys.stderr)
        sys.exit(1)
PYEOF

log "All plugins installed."

# ── 3. Pre-write plugin configurations ─────────────────────────────────────────
log "Writing plugin configurations..."
mkdir -p "$PLUGINS_CONF"

SEERR_CONF="$PLUGINS_CONF/Jellyfin.Plugin.SeerrFin.xml"
MOONBASE_CONF="$PLUGINS_CONF/Moonfin.Server.xml"

if [[ -f $SEERR_CONF ]]; then
    warn "SeerrFin config already exists, skipping."
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
    warn "Moonbase config already exists, skipping."
    MOONBASE_SECRET="<see $MOONBASE_CONF — field SeerrWebhookSecret>"
else
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

# ── 4. Restart Jellyfin ────────────────────────────────────────────────────────
log "Restarting Jellyfin so plugins load..."
(cd "$DIR" && docker compose restart jellyfin)
log "Jellyfin restarted."

# ── 5. One remaining manual step ──────────────────────────────────────────────
echo
warn "One manual step remaining — configure the Moonbase webhook in Seerr:"
warn "  Seerr → Settings → Notifications → Webhook → Add Webhook"
warn "  URL:         http://jellyfin:8096/Moonfin/webhook"
warn "  Auth header: X-Webhook-Secret: ${MOONBASE_SECRET}"
warn "  Events: Request Approved, Request Available, etc."
