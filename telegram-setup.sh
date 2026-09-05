#!/usr/bin/env bash
# Configures Telegram notifications in Sonarr and Radarr via their API:
# notifies when new content is added to tracking and when downloads finish.
# Uptime Kuma has no simple REST API for this — configure it manually from
# Settings → Notifications → Telegram (same bot token / chat id).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
[[ -f $ENV_FILE ]] || { echo "No se encontró $ENV_FILE"; exit 1; }
set -a; source "$ENV_FILE"; set +a

: "${TELEGRAM_BOT_TOKEN:?Falta TELEGRAM_BOT_TOKEN en .env}"
: "${TELEGRAM_CHAT_ID:?Falta TELEGRAM_CHAT_ID en .env}"
: "${SONARR_API_KEY:?Falta SONARR_API_KEY en .env}"
: "${RADARR_API_KEY:?Falta RADARR_API_KEY en .env}"

add_notification() {
    local name="$1" host="$2" port="$3" apikey="$4" body="$5"
    existing=$(curl -s "http://${host}:${port}/api/v3/notification" -H "X-Api-Key: ${apikey}" \
        | python3 -c "import json,sys; print(any(n['name']=='Telegram' for n in json.load(sys.stdin)))")
    if [[ $existing == "True" ]]; then
        echo "${name}: ya existe una notificación 'Telegram', omitiendo."
        return
    fi
    curl -s -o /dev/null -w "${name}: HTTP %{http_code}\n" -X POST \
        "http://${host}:${port}/api/v3/notification" \
        -H "X-Api-Key: ${apikey}" -H "Content-Type: application/json" \
        -d "${body}"
}

SONARR_BODY=$(cat <<JSON
{
  "onGrab": false,
  "onDownload": true,
  "onUpgrade": true,
  "onImportComplete": true,
  "onRename": false,
  "onSeriesAdd": true,
  "onSeriesDelete": false,
  "onEpisodeFileDelete": false,
  "onEpisodeFileDeleteForUpgrade": false,
  "onHealthIssue": false,
  "includeHealthWarnings": false,
  "onHealthRestored": false,
  "onApplicationUpdate": false,
  "onManualInteractionRequired": false,
  "name": "Telegram",
  "fields": [
    {"name": "botToken", "value": "${TELEGRAM_BOT_TOKEN}"},
    {"name": "chatId", "value": "${TELEGRAM_CHAT_ID}"},
    {"name": "topicId", "value": ""},
    {"name": "sendSilently", "value": false},
    {"name": "includeAppNameInTitle", "value": true},
    {"name": "includeInstanceNameInTitle", "value": false},
    {"name": "metadataLinks", "value": []}
  ],
  "implementationName": "Telegram",
  "implementation": "Telegram",
  "configContract": "TelegramSettings",
  "tags": []
}
JSON
)

RADARR_BODY=$(cat <<JSON
{
  "onGrab": false,
  "onDownload": true,
  "onUpgrade": true,
  "onRename": false,
  "onMovieAdded": true,
  "onMovieDelete": false,
  "onMovieFileDelete": false,
  "onMovieFileDeleteForUpgrade": false,
  "onHealthIssue": false,
  "includeHealthWarnings": false,
  "onHealthRestored": false,
  "onApplicationUpdate": false,
  "onManualInteractionRequired": false,
  "name": "Telegram",
  "fields": [
    {"name": "botToken", "value": "${TELEGRAM_BOT_TOKEN}"},
    {"name": "chatId", "value": "${TELEGRAM_CHAT_ID}"},
    {"name": "topicId", "value": ""},
    {"name": "sendSilently", "value": false},
    {"name": "includeAppNameInTitle", "value": true},
    {"name": "includeInstanceNameInTitle", "value": false},
    {"name": "metadataLinks", "value": []}
  ],
  "implementationName": "Telegram",
  "implementation": "Telegram",
  "configContract": "TelegramSettings",
  "tags": []
}
JSON
)

add_notification "Sonarr" "localhost" 8989 "$SONARR_API_KEY" "$SONARR_BODY"
add_notification "Radarr" "localhost" 7878 "$RADARR_API_KEY" "$RADARR_BODY"

echo
echo "Sonarr y Radarr ahora notifican por Telegram: series/películas añadidas y descargas finalizadas (incl. upgrades)."
echo "Para Uptime Kuma: Settings → Notifications → Add → Telegram, usa el mismo Bot Token y Chat ID, y actívala en cada monitor (o márcala como 'Default' al crearla)."
