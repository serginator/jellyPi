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

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "Configurando notificaciones de Telegram..."
    "$DIR/telegram-setup.sh"
else
    echo "TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID vacíos en .env, omito notificaciones de Telegram."
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

echo "post-setup.sh completado."
