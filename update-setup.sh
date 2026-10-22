#!/usr/bin/env bash
# Instala el gestor de actualizaciones de contenedores (update-containers.py).
# Es idempotente: se puede volver a ejecutar cuando se quiera.
#   1. Fija los servicios de linuxserver a su tag version-<x> (<SERVICE>_TAG en .env).
#   2. Recrea diun para que encole los tags nuevos en vez de avisar por Telegram.
#   3. Instala dos crons: poll cada 5 min (aprobaciones por Telegram) y
#      reconstrucciones el domingo a las 09:00.
#   4. Manda un mensaje de prueba por Telegram.
# Necesita TELEGRAM_BOT_TOKEN y TELEGRAM_CHAT_ID en .env y el stack arrancado.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
[[ -f $ENV_FILE ]] || { echo "No se encontró $ENV_FILE"; exit 1; }
set -a; source "$ENV_FILE"; set +a

: "${TELEGRAM_BOT_TOKEN:?Falta TELEGRAM_BOT_TOKEN en .env}"
: "${TELEGRAM_CHAT_ID:?Falta TELEGRAM_CHAT_ID en .env}"

chmod +x "$DIR/update-containers.py" "$DIR/diun/notify.sh"

echo "Fijando las imágenes de linuxserver a su versión actual..."
"$DIR/update-containers.py" pin

echo "Recreando diun para aplicar el notificador de cola..."
(cd "$DIR" && docker compose up -d diun)

echo "Instalando los crons..."
CRON_POLL="*/5 * * * *   $DIR/update-containers.py poll"
# Domingo 09:00: después del reinicio de las 08:05 y del prune de las 04:00.
CRON_REBUILDS="0 9 * * 0     $DIR/update-containers.py rebuilds"
(crontab -l 2>/dev/null | grep -v "update-containers.py" || true; \
  echo "$CRON_POLL"; echo "$CRON_REBUILDS") | crontab -

echo "Enviando mensaje de prueba por Telegram..."
"$DIR/update-containers.py" test-message

echo "update-setup.sh completado."
echo "Los avisos de versión nueva llegan con botones Actualizar/Omitir (tarda hasta 5 min en reaccionar al pulsar)."
echo "Estado: ./update-containers.py status — log: \$STORAGE/config/update-bot/update.log"
