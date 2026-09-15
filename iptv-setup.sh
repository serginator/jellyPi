#!/usr/bin/env bash
# Configures free Live TV (IPTV) in Jellyfin via its REST API using
# TDTChannels (https://github.com/LaQuay/TDTChannels), a free, actively
# maintained list of Spanish free-to-air channels (autonómicas, generalistas,
# internacionales...) with matching XMLTV EPG. Both the M3U and the EPG use
# the same tvg-id scheme, so Jellyfin auto-matches channels to the guide —
# no custom name-matching needed.
#
# TDTChannels' raw M3U lists several mirror/fallback URLs per channel under
# the same tvg-id (duplicated entries), which would otherwise show up as
# repeated channels in Jellyfin. This script downloads it, keeps only the
# first (primary) URL per channel, and writes the result to a local file
# inside Jellyfin's config volume, which is what the M3U tuner points to.
#
# Idempotent: safe to re-run — re-downloads and re-deduplicates the list,
# skips the tuner/provider if already present, and re-triggers a channel +
# guide refresh so updates (new channels, moved streams...) get picked up.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
[[ -f $ENV_FILE ]] || { echo "No se encontró $ENV_FILE"; exit 1; }
set -a; source "$ENV_FILE"; set +a

: "${JELLYFIN_API_KEY:?Falta JELLYFIN_API_KEY en .env (Dashboard → API Keys → +)}"
: "${STORAGE:?Falta STORAGE en .env}"

JELLYFIN_URL="http://localhost:8096"
AUTH_HEADER="Authorization: MediaBrowser Token=\"${JELLYFIN_API_KEY}\""
M3U_SOURCE_URL="https://www.tdtchannels.com/lists/tv.m3u"
EPG_URL="https://www.tdtchannels.com/epg/TV.xml.gz"

# Ruta en el host (montada como /config dentro del contenedor de Jellyfin).
M3U_HOST_DIR="${STORAGE}/config/jellyfin/iptv"
M3U_HOST_PATH="${M3U_HOST_DIR}/tv.m3u"
# Ruta tal y como la ve Jellyfin (dentro del contenedor).
M3U_CONTAINER_PATH="/config/iptv/tv.m3u"

jf_get() { curl -sf -H "$AUTH_HEADER" "${JELLYFIN_URL}$1"; }
jf_post() { curl -sf -X POST -H "$AUTH_HEADER" -H "Content-Type: application/json" -d "$2" "${JELLYFIN_URL}$1"; }

echo "Descargando lista de canales de TDTChannels..."
mkdir -p "$M3U_HOST_DIR"
curl -sf "$M3U_SOURCE_URL" -o "${M3U_HOST_PATH}.raw"

echo "Eliminando mirrors/duplicados (una URL por canal, la principal)..."
python3 -c "
import re

with open('${M3U_HOST_PATH}.raw', encoding='utf-8') as f:
    lines = f.read().splitlines()

header, entries, i = lines[0], [], 1
while i < len(lines):
    line = lines[i]
    if line.startswith('#EXTINF'):
        m = re.search(r'tvg-id=\"([^\"]*)\"', line)
        key = (m.group(1) if m else '') or line.split(',')[-1].strip()
        extra = []
        j = i + 1
        while j < len(lines) and lines[j].startswith('#'):
            extra.append(lines[j])
            j += 1
        url = lines[j] if j < len(lines) else None
        entries.append((key, line, extra, url))
        i = j + 1
    else:
        i += 1

seen, deduped = set(), []
for key, extinf, extra, url in entries:
    if key in seen or url is None:
        continue
    seen.add(key)
    deduped.append((extinf, extra, url))

with open('${M3U_HOST_PATH}', 'w', encoding='utf-8') as f:
    f.write(header + '\n')
    for extinf, extra, url in deduped:
        f.write(extinf + '\n')
        for e in extra:
            f.write(e + '\n')
        f.write(url + '\n')

print(f'{len(entries)} entradas originales -> {len(deduped)} canales únicos.')
"
rm -f "${M3U_HOST_PATH}.raw"

CONFIG=$(jf_get "/System/Configuration/livetv")

TUNER_ID=$(echo "$CONFIG" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for t in d.get('TunerHosts', []):
    if t.get('Url') == '$M3U_CONTAINER_PATH':
        print(t['Id'])
        break
")

if [[ -n "$TUNER_ID" ]]; then
    echo "Tuner M3U ya configurado ($TUNER_ID), omito creación."
else
    echo "Añadiendo tuner M3U (TDTChannels, lista deduplicada)..."
    TUNER_ID=$(jf_post "/LiveTv/TunerHosts" "{
        \"Type\": \"m3u\",
        \"Url\": \"$M3U_CONTAINER_PATH\",
        \"FriendlyName\": \"TDTChannels\",
        \"TunerCount\": 1,
        \"AllowHWTranscoding\": true,
        \"AllowFmp4TranscodingContainer\": false,
        \"AllowStreamSharing\": true,
        \"UserAgent\": \"\"
    }" | python3 -c "import json,sys; print(json.load(sys.stdin)['Id'])")
    echo "Tuner añadido: $TUNER_ID"
fi

PROVIDER_ID=$(echo "$CONFIG" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for p in d.get('ListingProviders', []):
    if p.get('Path') == '$EPG_URL':
        print(p['Id'])
        break
")

if [[ -n "$PROVIDER_ID" ]]; then
    echo "Proveedor EPG (XMLTV) ya configurado ($PROVIDER_ID), omito creación."
else
    echo "Añadiendo proveedor EPG XMLTV (TDTChannels)..."
    PROVIDER_ID=$(jf_post "/LiveTv/ListingProviders?validateListings=false&validateLogin=false" "{
        \"Type\": \"xmltv\",
        \"Path\": \"$EPG_URL\",
        \"EnableAllTuners\": true
    }" | python3 -c "import json,sys; print(json.load(sys.stdin)['Id'])")
    echo "Proveedor EPG añadido: $PROVIDER_ID"
fi

echo "Refrescando lista de canales..."
CHANNELS_TASK_ID=$(jf_get "/ScheduledTasks" | python3 -c "
import json, sys
for t in json.load(sys.stdin):
    if t['Key'] == 'RefreshInternetChannels':
        print(t['Id'])
        break
")
jf_post "/ScheduledTasks/Running/${CHANNELS_TASK_ID}" "" >/dev/null

tries=24
while (( tries > 0 )); do
    state=$(jf_get "/ScheduledTasks/${CHANNELS_TASK_ID}" | python3 -c "import json,sys; print(json.load(sys.stdin)['State'])")
    [[ $state == "Idle" ]] && break
    sleep 5
    ((tries--))
done

echo "Refrescando guía EPG (puede tardar varios minutos con la lista completa)..."
GUIDE_TASK_ID=$(jf_get "/ScheduledTasks" | python3 -c "
import json, sys
for t in json.load(sys.stdin):
    if t['Key'] == 'RefreshGuide':
        print(t['Id'])
        break
")
jf_post "/ScheduledTasks/Running/${GUIDE_TASK_ID}" "" >/dev/null

tries=90
while (( tries > 0 )); do
    state=$(jf_get "/ScheduledTasks/${GUIDE_TASK_ID}" | python3 -c "import json,sys; print(json.load(sys.stdin)['State'])")
    [[ $state == "Idle" ]] && break
    sleep 10
    ((tries--))
done

TOTAL=$(jf_get "/LiveTv/Channels?limit=1000" | python3 -c "import json,sys; print(json.load(sys.stdin)['TotalRecordCount'])")
WITH_EPG=$(jf_get "/LiveTv/Channels?limit=1000&fields=ProgramInfo" | python3 -c "
import json, sys
items = json.load(sys.stdin)['Items']
print(sum(1 for c in items if c.get('CurrentProgram')))
")

echo
echo "iptv-setup.sh completado: $TOTAL canales importados, $WITH_EPG con programación EPG activa ahora mismo."
echo "Live TV disponible en Jellyfin (icono de TV en el menú lateral)."
