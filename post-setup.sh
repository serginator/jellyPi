#!/usr/bin/env bash
# Run this once after `docker compose up -d` (Sonarr/Radarr must have started at
# least once — they generate their own API key in config.xml on first boot).
# Fills in SONARR_API_KEY/RADARR_API_KEY in .env by reading them straight from
# config.xml, recreates unpackerr so it picks up the real keys, and wires up
# Telegram notifications and decluttarr if their .env variables are set.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
[[ -f $ENV_FILE ]] || { echo "No se encontró $ENV_FILE"; exit 1; }

STORAGE=$(grep -m1 "^STORAGE=" "$ENV_FILE" | cut -d= -f2-)
STORAGE=${STORAGE:-/mnt/storage}

wait_for_key() {
    local name="$1" config_xml="$2" tries=30
    while [[ ! -f $config_xml ]] && (( tries > 0 )); do
        echo "Esperando a que $name genere su config.xml... ($tries)" >&2
        sleep 5
        ((tries--))
    done
    if [[ ! -f $config_xml ]]; then
        echo "$name no generó config.xml a tiempo — ¿está el contenedor arrancado (docker compose up -d)?" >&2
        return 1
    fi
    grep -o "<ApiKey>[^<]*</ApiKey>" "$config_xml" | sed "s/<[^>]*>//g"
}

update_env_key() {
    local var="$1" value="$2"
    if grep -q "^${var}=.\+" "$ENV_FILE"; then
        echo "$var ya tiene valor en .env, no lo toco."
    else
        sed -i "s|^${var}=.*|${var}=${value}|" "$ENV_FILE"
        echo "$var actualizado en .env."
    fi
}

echo "Leyendo API keys de Sonarr y Radarr..."
SONARR_KEY=$(wait_for_key "Sonarr" "$STORAGE/config/sonarr/config.xml")
RADARR_KEY=$(wait_for_key "Radarr" "$STORAGE/config/radarr/config.xml")

update_env_key SONARR_API_KEY "$SONARR_KEY"
update_env_key RADARR_API_KEY "$RADARR_KEY"

set -a; source "$ENV_FILE"; set +a

echo "Recreando unpackerr para aplicar las API keys..."
(cd "$DIR" && docker compose up -d unpackerr)

echo "Configurando restricciones de release en Radarr..."
RADARR_PROFILES=$(curl -s "http://localhost:7878/api/v3/releaseprofile" -H "X-Api-Key: $RADARR_KEY")
if echo "$RADARR_PROFILES" | grep -q '"HQ Pre"'; then
    echo "Restricción 'HQ Pre' ya existe en Radarr, no la toco."
else
    curl -s -X POST "http://localhost:7878/api/v3/releaseprofile" \
        -H "X-Api-Key: $RADARR_KEY" \
        -H "Content-Type: application/json" \
        -d '{"name":"Bloquear HQ Pre","enabled":true,"required":[],"ignored":["HQ Pre"],"indexerId":0,"tags":[]}' \
        > /dev/null
    echo "Restricción 'HQ Pre' añadida a Radarr."
fi

echo "Configurando restricciones de release en Sonarr..."
# Perfil global (sin tags): rechaza releases cuyo título contenga estos términos.
# Idempotente: crea el perfil si no existe, o añade los términos que falten.
# AV1: la Pi 4 no decodifica AV1 por hardware y transcodificarlo por CPU va por
# debajo de tiempo real (~0,97x) -> saltos. Se prefieren releases H.264/HEVC.
SONARR_IGNORED='["English Dub","Dub]","SUBFRENCH","AV1"]'
SONARR_PROFILES=$(curl -s "http://localhost:8989/api/v3/releaseprofile" -H "X-Api-Key: $SONARR_KEY")
SONARR_PROFILE_JSON=$(SONARR_IGNORED="$SONARR_IGNORED" python3 -c "
import json, os, sys
wanted = json.loads(os.environ['SONARR_IGNORED'])
profiles = json.loads(sys.stdin.read() or '[]')
p = next((p for p in profiles if not p.get('tags')), None)
if p is None:
    p = {'name': 'Bloquear dubs y SUBFRENCH', 'enabled': True, 'required': [], 'ignored': [], 'indexerId': 0, 'tags': []}
p['ignored'] += [t for t in wanted if t not in p['ignored']]
print(json.dumps(p))
" <<< "$SONARR_PROFILES")
SONARR_PROFILE_ID=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('id',''))" "$SONARR_PROFILE_JSON")
if [[ -n "$SONARR_PROFILE_ID" ]]; then
    curl -s -X PUT "http://localhost:8989/api/v3/releaseprofile/$SONARR_PROFILE_ID" \
        -H "X-Api-Key: $SONARR_KEY" -H "Content-Type: application/json" \
        -d "$SONARR_PROFILE_JSON" > /dev/null
else
    curl -s -X POST "http://localhost:8989/api/v3/releaseprofile" \
        -H "X-Api-Key: $SONARR_KEY" -H "Content-Type: application/json" \
        -d "$SONARR_PROFILE_JSON" > /dev/null
fi
echo "Restricciones de Sonarr aplicadas: $SONARR_IGNORED"

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "Configurando notificaciones de Telegram..."
    "$DIR/telegram-setup.sh"
    echo "Configurando el gestor de actualizaciones de contenedores..."
    "$DIR/update-setup.sh"
else
    echo "TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID vacíos en .env, omito notificaciones de Telegram y el gestor de actualizaciones."
fi

if [[ -n "${QBITTORRENT_PASSWORD:-}" ]]; then
    echo "Configurando decluttarr..."
    "$DIR/decluttarr-setup.sh"
    # 'restart', not 'up -d': compose doesn't detect content changes in a bind-mounted
    # file, only in the service definition — a real restart is needed to re-read it.
    (cd "$DIR" && docker compose restart decluttarr)
else
    echo "QBITTORRENT_PASSWORD vacío en .env, omito configuración de decluttarr."
fi

if [[ -n "${JELLYFIN_API_KEY:-}" && -n "${TMDB_API_KEY:-}" ]]; then
    echo "Configurando plugins de Jellyfin (SeerrFin, File Transformator, Intro Skipper)..."
    "$DIR/jellyfin-plugins-setup.sh"
else
    echo "JELLYFIN_API_KEY o TMDB_API_KEY vacíos en .env, omito setup de plugins de Jellyfin."
    echo "Ejecuta ./jellyfin-plugins-setup.sh manualmente cuando estén disponibles."
fi

echo "post-setup.sh completado."
