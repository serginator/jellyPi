#!/usr/bin/env bash
# Fully automated setup for 3 Jellyfin plugins: File Transformator, SeerrFin,
# Intro Skipper.
# - Adds plugin repositories to Jellyfin
# - Installs the plugins via API
# - Pre-writes their configurations
# - Restarts Jellyfin
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
JF_AUTH="Authorization: MediaBrowser Token=\"${JELLYFIN_API_KEY}\""
PLUGINS_CONF="$STORAGE/config/jellyfin/data/plugins/configurations"
SEERR_CONF="$PLUGINS_CONF/Jellyfin.Plugin.SeerrFin.xml"

mkdir -p "$PLUGINS_CONF"

# ── 1. Add plugin repositories ─────────────────────────────────────────────────
log "Adding plugin repositories to Jellyfin..."

REPOS_JSON='[
  {"Name":"Jellyfin Stable","Url":"https://repo.jellyfin.org/files/plugin/manifest.json","Enabled":true},
  {"Name":"File Transformator","Url":"https://www.iamparadox.dev/jellyfin/plugins/manifest.json","Enabled":true},
  {"Name":"SeerrFin","Url":"https://raw.githubusercontent.com/varunaditya-plus/SeerrFin/main/manifest.json","Enabled":true},
  {"Name":"Intro Skipper","Url":"https://intro-skipper.org/manifest.json","Enabled":true}
]'

curl -sf -X POST "$JF_URL/Repositories" \
    -H "$JF_AUTH" -H "Content-Type: application/json" \
    -d "$REPOS_JSON" \
    || die "Failed to add repositories. Is Jellyfin running and JELLYFIN_API_KEY correct?"

log "Repositories added."

# ── 2. Install plugins via API ─────────────────────────────────────────────────
log "Installing plugins..."

# Format: "<manifest url>|<plugin name>". Several manifests list many plugins
# (iamparadox.dev has six), so always pick by name, never "the first one".
MANIFEST_URLS=(
    "https://www.iamparadox.dev/jellyfin/plugins/manifest.json|File Transformation"
    "https://raw.githubusercontent.com/varunaditya-plus/SeerrFin/main/manifest.json|SeerrFin"
    "https://intro-skipper.org/manifest.json|Intro Skipper"
)

python3 - "${MANIFEST_URLS[@]}" <<PYEOF
import json, sys, urllib.request, urllib.parse

JF_URL = "http://localhost:8096"
API_KEY = "$(echo "$JELLYFIN_API_KEY" | sed "s/\"/\\\\\"/g")"
HEADERS = {
    "Authorization": f'MediaBrowser Token="{API_KEY}"',
    "Content-Type": "application/json",
}

# Some manifests depend on the Jellyfin version (intro-skipper.org reads it from
# the User-Agent; without it, it redirects to GitHub) or refuse Python's default
# User-Agent (iamparadox.dev answers 403). Ask like Jellyfin does.
jf_version = json.loads(urllib.request.urlopen(f"{JF_URL}/System/Info/Public", timeout=15).read())["Version"]

for arg in sys.argv[1:]:
    manifest_url, _, want = arg.partition("|")
    try:
        req = urllib.request.Request(manifest_url, headers={"User-Agent": f"Jellyfin-Server/{jf_version}"})
        data = json.loads(urllib.request.urlopen(req, timeout=15).read())
        pkg = next(p for p in data if p["name"] == want)
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

# ── 4. Restart Jellyfin ────────────────────────────────────────────────────────
log "Restarting Jellyfin so plugins load..."
(cd "$DIR" && docker compose restart jellyfin)
log "Jellyfin restarted."

# ── 5. Intro Skipper: analysis at 03:00 ────────────────────────────────────────
# The plugin analyzes the audio of every episode (heavy on the Pi's CPU and USB
# disk). Its default is 00:00, the same time as RomM's nightly scan, so move it.
# The task only exists once Jellyfin has loaded the plugin (~4 min after restart).
log "Waiting for Jellyfin to come back (up to 10 min)..."
for _ in $(seq 1 60); do
    curl -sf -m 5 "$JF_URL/health" >/dev/null && break
    sleep 10
done

JF_API_KEY="$JELLYFIN_API_KEY" python3 - <<'PYEOF'
import json, os, sys, urllib.request

H = {"Authorization": f'MediaBrowser Token="{os.environ["JF_API_KEY"]}"',
     "Content-Type": "application/json"}

def call(path, data=None, method="GET"):
    req = urllib.request.Request("http://localhost:8096" + path, data=data, method=method, headers=H)
    body = urllib.request.urlopen(req, timeout=15).read()
    return json.loads(body) if body else None

try:
    task = next(t for t in call("/ScheduledTasks") if t["Name"] == "Detect and Analyze Media Segments")
    trigger = [{"Type": "DailyTrigger", "TimeOfDayTicks": 3 * 3600 * 10**7}]
    call(f"/ScheduledTasks/{task['Id']}/Triggers", json.dumps(trigger).encode(), "POST")
    print("[plugins] Intro Skipper analysis scheduled daily at 03:00")
except Exception as e:
    print(f"[plugins] WARNING: could not move the Intro Skipper schedule: {e}", file=sys.stderr)
PYEOF

log "Done. All plugins installed and configured."
