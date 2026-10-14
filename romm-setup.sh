#!/usr/bin/env bash
# Prepares RomM: generates its secrets in .env (only the ones that are empty),
# enables the compose profile and creates its config dirs. Safe to re-run —
# existing values are never overwritten. Then start it with:
#   docker compose up -d
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
[[ -f $ENV_FILE ]] || { echo "No se encontró $ENV_FILE"; exit 1; }
set -a; source "$ENV_FILE"; set +a

STORAGE=${STORAGE:-/mnt/storage}

# Set KEY=value in .env: replace an empty/existing line, or append if missing.
set_env() {
    local key=$1 value=$2
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

for key in ROMM_DB_PASSWORD ROMM_DB_ROOT_PASSWORD ROMM_AUTH_SECRET_KEY; do
    if [[ -z ${!key:-} ]]; then
        set_env "$key" "$(openssl rand -hex 32)"
        echo "Generado $key"
    fi
done

if ! grep -q "^COMPOSE_PROFILES=.*romm" "$ENV_FILE"; then
    set_env COMPOSE_PROFILES romm
    echo "Añadido COMPOSE_PROFILES=romm"
fi
chmod 600 "$ENV_FILE"

mkdir -p "$STORAGE"/config/romm/{resources,redis,assets,config,db}
# .ldci = disc-index files from the emulator; without this RomM lists each as a game
[[ -s $STORAGE/config/romm/config/config.yml ]] || cat > "$STORAGE/config/romm/config/config.yml" <<'EOF'
exclude:
  roms:
    single_file:
      extensions: ["ldci"]
EOF
[[ -d $STORAGE/data/roms ]] || echo "AVISO: no existe $STORAGE/data/roms — RomM no verá ninguna ROM."

echo ""
echo "Listo. Arranca con: docker compose up -d   (primer arranque ~1-2 min por MariaDB)"
echo "Paso manual inevitable (RomM no tiene API para esto): abre http://jellypi.local:8085,"
echo "crea el usuario admin en el asistente y lanza el primer escaneo desde Scan."
if [[ -z ${SCREENSCRAPER_USER:-} || -z ${RETROACHIEVEMENTS_API_KEY:-} ]]; then
    echo "Falta SCREENSCRAPER_USER/PASSWORD o RETROACHIEVEMENTS_API_KEY en .env — ponlos antes de arrancar (o después, con: docker compose up -d romm)."
fi
